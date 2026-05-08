;; Read-only introspection tool for the running agent.
;;
;; The query language is intentionally *not* Fennel eval. It accepts a tiny
;; Fennel-shaped data language and interprets a fixed set of operators over a
;; sanitized, allowlisted state object.

(local json (require :fen.util.json))
(local extensions (require :fen.core.extensions))
(local agent-mod (require :fen.core.agent))
(local types (require :fen.core.types))

(local MAX-BYTES 8192)

(fn result [_api text is-error?]
  {:content [(types.text-block (or text ""))]
   :is-error? (or is-error? false)})

(fn err [api msg] (result api (.. "error: " msg) true))
(fn ok [api text] (result api text false))

(fn ch [s i] (string.sub s i i))
(fn whitespace? [c] (not= nil (string.find " \t\r\n" c 1 true)))

(fn parse-string [s pos]
  (let [out []
        n (length s)]
    (var i (+ pos 1))
    (var done? false)
    (var error-msg nil)
    (while (and (<= i n) (not done?))
      (let [c (ch s i)]
        (if (= c "\"")
            (set done? true)
            (= c "\\")
            (let [nxt (ch s (+ i 1))]
              (if (= nxt "")
                  (set error-msg "unterminated escape in string")
                  (do
                    (table.insert out
                                  (if (= nxt "n") "\n"
                                      (= nxt "r") "\r"
                                      (= nxt "t") "\t"
                                      nxt))
                    (set i (+ i 1)))))
            (table.insert out c)))
      (set i (+ i 1)))
    (if error-msg
        (values nil i error-msg)
        done?
        (values (table.concat out) i nil)
        (values nil i "unterminated string"))))

(fn atom-value [tok]
  (let [n (tonumber tok)]
    (if n n
        (= tok "nil") nil
        (= tok "true") true
        (= tok "false") false
        (= (string.sub tok 1 1) ":") (string.sub tok 2)
        tok)))

(fn parse-atom [s pos]
  (let [n (length s)]
    (var i pos)
    (while (and (<= i n)
                (not (whitespace? (ch s i)))
                (not= (ch s i) "(")
                (not= (ch s i) ")"))
      (set i (+ i 1)))
    (if (= i pos)
        (values nil i (.. "unexpected character: " (ch s pos)))
        (values (atom-value (string.sub s pos (- i 1))) i nil))))

(fn skip-ws [s pos]
  (let [n (length s)]
    (var i pos)
    (while (and (<= i n) (whitespace? (ch s i)))
      (set i (+ i 1)))
    i))

(var parse-expr nil)

(fn parse-list [s pos]
  (let [items []
        n (length s)]
    (var i (+ pos 1))
    (var done? false)
    (var error-msg nil)
    (while (and (<= i n) (not done?) (not error-msg))
      (set i (skip-ws s i))
      (if (> i n)
          (set error-msg "unterminated list")
          (= (ch s i) ")")
          (do (set done? true)
              (set i (+ i 1)))
          (let [(v next-i err-msg) (parse-expr s i)]
            (if err-msg
                (set error-msg err-msg)
                (do (table.insert items v)
                    (set i next-i))))))
    (if error-msg
        (values nil i error-msg)
        (not done?)
        (values nil i "unterminated list")
        (values items i nil))))

(set parse-expr
     (fn [s pos]
       (let [i (skip-ws s pos)
             c (ch s i)]
         (if (= c "")
             (values nil i "empty query")
             (= c "(")
             (parse-list s i)
             (= c ")")
             (values nil i "unexpected ')'" )
             (= c "\"")
             (parse-string s i)
             (parse-atom s i)))))

;; @doc fen.extensions.agent_state.tool.parse-query
;; kind: function
;; signature: (parse-query s) -> expr|nil, err|nil
;; summary: Parse the agent_state mini-query language into an expression tree, returning a user-facing parse error on invalid input.
;; tags: tool agent-state query
(fn parse-query [s]
  (if (or (not s) (= s ""))
      (values nil "missing query")
      (let [(expr pos err-msg) (parse-expr s 1)]
        (if err-msg
            (values nil err-msg)
            (let [end-pos (skip-ws s pos)]
              (if (<= end-pos (length s))
                  (values nil (.. "trailing input near: " (string.sub s end-pos)))
                  (values expr nil)))))))

(fn array? [t]
  (and (= (type t) :table)
       (or (= (length t) 0)
           (not= (. t 1) nil))))

(fn table-keys [t]
  (let [out []]
    (each [k _ (pairs (or t {}))]
      (table.insert out (tostring k)))
    (table.sort out)
    out))

(fn table-count [t]
  (if (array? t)
      (length t)
      (do
        (var n 0)
        (each [_ _ (pairs (or t {}))]
          (set n (+ n 1)))
        n)))

(fn public-tools [agent]
  (let [out []]
    (each [_ t (ipairs (or agent.tools []))]
      (table.insert out {:name t.name
                         :description t.description
                         :parameters t.parameters}))
    out))

(fn summarize-usage [agent]
  (let [u {:input 0 :output 0 :cache-read 0 :cache-write 0 :total-tokens 0
           :last-input 0 :last-output 0}]
    (each [_ msg (ipairs (or agent.messages []))]
      (when (and (= msg.role :assistant) msg.usage)
        (let [mu msg.usage
              input (or mu.input 0)
              output (or mu.output 0)
              cr (or mu.cache-read 0)
              cw (or mu.cache-write 0)
              total (or mu.total-tokens (+ input output cr cw))]
          (set u.input (+ u.input input))
          (set u.output (+ u.output output))
          (set u.cache-read (+ u.cache-read cr))
          (set u.cache-write (+ u.cache-write cw))
          (set u.total-tokens (+ u.total-tokens total))
          (set u.last-input input)
          (set u.last-output output))))
    u))

(fn cwd []
  (or (os.getenv :PWD) "."))

(fn panel-status []
  "Return registered panels with evaluated height/visible state. Height is
  called with a minimal neutral context; presenter-specific geometry may vary,
  but v1 first-party panels only need width to report hidden vs visible."
  (let [out []
        ctx {:w 100}]
    (each [_ p (ipairs (extensions.list :panels))]
      (let [(ok? h-or-err) (pcall p.height ctx)
            rec {:name p.name
                 :owner p.owner
                 :placement p.placement
                 :order p.order}]
        (if ok?
            (do (set rec.height (or h-or-err 0))
                (set rec.visible? (> (or h-or-err 0) 0)))
            (do (set rec.height-error (tostring h-or-err))
                (set rec.visible? false)))
        (table.insert out rec)))
    out))

(fn extensions-state []
  {:loaded (extensions.list :extensions)
   :tools (extensions.list :tools)
   :commands (extensions.list :commands)
   :presenters (extensions.list :presenters)
   :panels (panel-status)
   :event-handlers (extensions.list :event-handlers)
   :prompt-fragments
   (extensions.list :prompt-fragments)})

;; @doc fen.extensions.agent_state.tool.sanitized-state
;; kind: function
;; signature: (sanitized-state agent ?api) -> table
;; summary: Build the redacted agent-state snapshot exposed to the agent_state tool without leaking raw mutable agent internals.
;; tags: tool agent-state introspection
(fn sanitized-state [agent _api]
  (let [state {}]
    (tset state :messages (or agent.messages []))
    (tset state :tools (public-tools agent))
    (tset state :system-prompt agent.system-prompt)
    (tset state :model agent.model)
    (tset state :provider-name agent.provider-name)
    (tset state :max-tokens agent.max-tokens)
    (tset state :usage (summarize-usage agent))
    (tset state :safety-cap agent-mod.SAFETY-CAP)
    (tset state :extensions (extensions-state))
    (tset state :errors (extensions.list-errors))
    (tset state :error-log-path (extensions.error-log-path))
    (tset state :cwd (cwd))
    state))

(fn normalize-index [idx len]
  (if (< idx 0)
      (+ len idx 1)
      (+ idx 1)))

(fn get-key [v key]
  (if (= (type v) :table)
      (if (= key :length)
          (table-count v)
          (= key :first)
          (. v 1)
          (= key :last)
          (. v (length v))
          (= (type key) :number)
          (. v (normalize-index (math.floor key) (length v)))
          (. v key))
      nil))

(var eval-query nil)

(fn eval-list [expr state]
  (let [op (. expr 1)]
    (if (= op :get)
        (let [argc (length expr)
              first-arg (. expr 2)]
          (var v state)
          (var start 2)
          ;; `(:get :messages -1)` starts from the root state. `(:get
          ;; (:last ...) :stop-reason)` starts from a nested query result.
          (when (= (type first-arg) :table)
            (set v (eval-query first-arg state))
            (set start 3))
          (for [i start argc]
            (set v (get-key v (. expr i))))
          v)
        (= op :keys)
        (table-keys (eval-query (. expr 2) state))
        (= op :count)
        (table-count (eval-query (. expr 2) state))
        (= op :pluck)
        (let [items (eval-query (. expr 2) state)
              key (. expr 3)
              out []]
          (each [_ item (ipairs (or items []))]
            (table.insert out (get-key item key)))
          out)
        (= op :where)
        (let [items (eval-query (. expr 2) state)
              key (. expr 3)
              wanted (. expr 4)
              out []]
          (each [_ item (ipairs (or items []))]
            (when (= (get-key item key) wanted)
              (table.insert out item)))
          out)
        (= op :slice)
        (let [items (eval-query (. expr 2) state)
              start (math.floor (or (. expr 3) 0))
              limit (math.floor (or (. expr 4) (length (or items []))))
              len (length (or items []))
              first (normalize-index start len)
              out []]
          (for [i first (math.min len (+ first limit -1))]
            (table.insert out (. items i)))
          out)
        (= op :first)
        (let [items (eval-query (. expr 2) state)] (. items 1))
        (= op :last)
        (let [items (eval-query (. expr 2) state)] (. items (length (or items []))))
        (error (.. "unknown operator: " (tostring op))))))

;; @doc fen.extensions.agent_state.tool.eval-query
;; kind: function
;; signature: (eval-query expr state) -> any
;; summary: Evaluate the parsed agent_state query operators against the sanitized snapshot without exposing general code execution.
;; tags: tool agent-state query eval
(set eval-query
     (fn [expr state]
       (if (= (type expr) :table)
           (eval-list expr state)
           ;; A bare atom is a root lookup shorthand, e.g. :model.
           (get-key state expr))))

(fn render-json [value]
  (let [(ok? encoded) (pcall json.encode value)]
    (if ok? encoded (.. "<json encode error: " (tostring encoded) ">"))))

(fn render-fennel [value]
  (let [(loaded? fennel) (pcall require :fennel)]
    (if (and loaded? fennel.view)
        (fennel.view value {:one-line? false :max-sparse-gap 3})
        (render-json value))))

(fn truncate [s max-bytes]
  (let [cap (or max-bytes MAX-BYTES)]
    (if (> (length s) cap)
        (.. (string.sub s 1 cap) "\n[truncated: kept " (tostring cap) " bytes]")
        s)))

;; @doc fen.extensions.agent_state.tool.execute
;; kind: function
;; signature: (execute args ctx ?api) -> AgentToolResult
;; summary: Execute an agent_state query against sanitized agent context and render the result as JSON or Fennel with truncation.
;; tags: tool agent-state execute
(fn execute [args ctx ?api]
  (if (or (not ctx) (not ctx.agent))
      (err ?api "agent_state requires agent context")
      (let [(expr parse-err) (parse-query args.query)]
        (if parse-err
            (err ?api parse-err)
            (let [state (sanitized-state ctx.agent ?api)
                  (eval-ok? value-or-err) (pcall eval-query expr state)]
              (if (not eval-ok?)
                  (err ?api value-or-err)
                  (let [fmt (or args.format :json)
                        rendered (if (= fmt :fennel)
                                     (render-fennel value-or-err)
                                     (= fmt :json)
                                     (render-json value-or-err)
                                     nil)]
                    (if rendered
                        (ok ?api (truncate rendered args.max_bytes))
                        (err ?api (.. "unknown format: " (tostring fmt)))))))))))

{:execute execute
 :parse-query parse-query
 :eval-query eval-query
 :sanitized-state sanitized-state}
