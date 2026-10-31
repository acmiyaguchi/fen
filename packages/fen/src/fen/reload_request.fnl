;; Deferred agent reload requests; live on the run-state so they are consumed only at that run's idle boundary.

(local M {})

(fn normalized-scope [value]
  (let [scope (tostring (or value :reload))]
    (if (= scope "reload") :reload
        (= scope "registries") :registries
        (= scope "extension") :extension
        nil)))

;; @doc fen.reload_request.enqueue!
;; kind: function
;; signature: (enqueue! state request) -> ok?, request|error
;; summary: Validate and append an agent-requested reload, single-extension reload (scope :extension with a :name, #627), or explicitly scoped recovery request to one interactive run state's deferred queue.
;; tags: reload recovery runtime agent
(fn M.enqueue! [state request]
  (let [scope (normalized-scope (?. request :scope))
        reason (tostring (or (?. request :reason) ""))
        name (and (?. request :name) (tostring request.name))]
    (if (not scope)
        (values false "scope must be reload, registries, or extension")
        (and (= scope :extension) (or (not name) (not (name:match "^%S+$"))))
        (values false "extension scope requires a name without whitespace")
        (= reason "")
        (values false "reason is required")
        (do
          (when (= state.reload-requests nil)
            (set state.reload-requests []))
          (let [entry {:scope scope
                       :name (if (= scope :extension) name nil)
                       :reason reason
                       :force? (= (?. request :force?) true)}]
            ;; Coalesce by scope+force so a looping agent cannot stack reloads; latest reason wins.
            (var existing nil)
            (each [_ queued (ipairs state.reload-requests) &until existing]
              (when (and (= queued.scope entry.scope)
                         (= queued.force? entry.force?)
                         (= queued.name entry.name))
                (set existing queued)))
            (if existing
                (do
                  (set existing.reason entry.reason)
                  (values true existing))
                (do
                  (table.insert state.reload-requests entry)
                  (values true entry))))))))

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
              ;; A synchronous throw in the dispatch prelude must not escape the tick loop.
              (let [(ok err) (pcall execute! request)]
                (when (not ok)
                  (io.stderr:write (.. "[warn] deferred reload failed: "
                                       (tostring err) "\n"))))
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
    (if (= scope :extension)
        (.. "/reload-extension " request.name)
        (= scope :registries)
        (if force? "/reload --all --recover registries"
            "/reload --recover registries")
        force?
        "/reload --all"
        "/reload")))

M
