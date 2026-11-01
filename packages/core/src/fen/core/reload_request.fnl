;; Agent reload requests, deferred as exclusive jobs of the one scheduler
;; (fen.core.tasks): they run at an idle boundary, after any pending turn.

(local M {})

(fn normalized-scope [value]
  (let [scope (tostring (or value :reload))]
    (if (= scope "reload") :reload
        (= scope "registries") :registries
        (= scope "extension") :extension
        nil)))

;; @doc fen.core.reload_request.enqueue!
;; kind: function
;; signature: (enqueue! state request) -> ok?, request|error
;; summary: Validate an agent-requested reload, single-extension reload (scope :extension with a :name, #627), or explicitly scoped recovery, and request it as an exclusive job (fen.core.tasks.request-job!): it runs when the session is idle, after any pending turn start. A request matching one still waiting (scope, name, force) only updates its reason.
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
        (let [tasks (require :fen.core.tasks)
              events (require :fen.core.extensions.events)
              entry {: scope
                     :name (if (= scope :extension) name nil)
                     : reason
                     :force? (= (?. request :force?) true)}
              line (M.command-line entry)]
          ;; Coalesced by key so a looping agent cannot stack reloads.
          (tasks.request-job! {:key (.. "reload-request:" line)
                               : reason
                               :label :reload-request
                               :on-spawn (tasks.adopter state)
                               :run (fn [_hid]
                                      (events.emit {:type :info
                                                    :text (.. "reload request> executing "
                                                              (tostring scope)
                                                              ": " reason)})
                                      ;; Inside this job, /reload runs inline.
                                      ((. (require :fen.core.extensions.register.command)
                                          :dispatch) line state))})
          (values true entry)))))

;; @doc fen.core.reload_request.command-line
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
