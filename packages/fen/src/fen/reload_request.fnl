;; Deferred agent reload requests.
;;
;; Requests live on the interactive run-state rather than the extension
;; singleton so they are tied to one presenter run and can only be consumed at
;; that run's idle boundary.

(local M {})

(fn normalized-scope [value]
  (let [scope (tostring (or value :reload))]
    (if (= scope "reload") :reload
        (= scope "registries") :registries
        nil)))

;; @doc fen.reload_request.enqueue!
;; kind: function
;; signature: (enqueue! state request) -> ok?, request|error
;; summary: Validate and append an agent-requested reload or explicitly scoped recovery request to one interactive run state's deferred queue.
;; tags: reload recovery runtime agent
(fn M.enqueue! [state request]
  (let [scope (normalized-scope (?. request :scope))
        reason (tostring (or (?. request :reason) ""))]
    (if (not scope)
        (values false "scope must be reload or registries")
        (= reason "")
        (values false "reason is required")
        (do
          (when (= state.reload-requests nil)
            (set state.reload-requests []))
          (let [entry {:scope scope
                       :reason reason
                       :force? (= (?. request :force?) true)}]
            (table.insert state.reload-requests entry)
            (values true entry))))))

;; @doc fen.reload_request.drain!
;; kind: function
;; signature: (drain! state execute!) -> executed?, request
;; summary: Remove and execute one queued reload request only when the interactive run has no active turn, stream, or tool call.
;; tags: reload recovery runtime agent
(fn M.drain! [state execute!]
  "The presenter calls this after finishing a turn. `state.busy?` covers
   streaming and tool execution because both occur inside the active turn
   coroutine; `state.turn` is checked independently as a defensive guard."
  (if (or state.busy? state.turn)
      (values false nil)
      (let [queue (or state.reload-requests [])
            request (. queue 1)]
        (if request
            (do
              (table.remove queue 1)
              (execute! request)
              (values true request))
            (values false nil)))))

;; @doc fen.reload_request.command-line
;; kind: function
;; signature: (command-line request) -> string
;; summary: Convert one validated deferred request into the ordinary reload command line used by the interactive command dispatcher.
;; tags: reload recovery commands
(fn M.command-line [request]
  (let [scope (normalized-scope (?. request :scope))
        force? (= (?. request :force?) true)]
    (if (= scope :registries)
        (if force? "/reload --all --recover registries" "/reload --recover registries")
        force? "/reload --all"
        "/reload")))

M
