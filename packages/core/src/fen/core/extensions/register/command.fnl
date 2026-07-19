(local state (require :fen.core.extensions.state))
(local util (require :fen.core.extensions.util))
(local events (require :fen.core.extensions.events))

(local M {})

;; @doc fen.core.extensions.register.command.register
;; kind: function
;; signature: (register spec owner handle-result) -> register-result
;; summary: Validate and install a slash-command contribution keyed by :name with its handler and command metadata.
;; tags: extensions register commands
(fn M.register [spec owner handle-result]
  (when (or (not spec) (not spec.name))
    (error "register :command requires {:name ...}"))
  (when (not= (type spec.handler) :function)
    (error "register :command requires {:handler fn}"))
  (let [name spec.name
        (record unregister) (util.set-tagged! state.commands-extra name spec owner)]
    (handle-result :command name owner unregister)))

;; @doc fen.core.extensions.register.command.unregister-by-owner
;; kind: function
;; signature: (unregister-by-owner owner) -> nil
;; summary: Remove all slash commands installed by owner so extension reloads replace commands without stale aliases.
;; tags: extensions register commands reload
(fn M.unregister-by-owner [owner]
  (each [name rec (pairs state.commands-extra)]
    (when (= rec.__owner owner)
      (tset state.commands-extra name nil))))

(fn parse-slash [line]
  "Split `/foo bar baz` into (\"foo\", \"bar baz\")."
  (let [stripped (string.match line "^/(.*)$")]
    (if (or (not stripped) (= stripped ""))
        (values nil "")
        (let [space-idx (string.find stripped "%s")]
          (if space-idx
              (values (string.sub stripped 1 (- space-idx 1))
                      (string.sub stripped (+ space-idx 1)))
              (values stripped ""))))))

(local first-line (. (require :fen.util.text) :first-line))

;; @doc fen.core.extensions.register.command.dispatch
;; kind: function
;; signature: (dispatch line caller-state) -> nil
;; summary: Parse a slash command line, enforce idle-only guards, pcall-isolate the handler, and emit user-facing errors.
;; tags: extensions commands events
(fn M.dispatch [line caller-state]
  "Look up and pcall-isolate a registered slash command."
  (let [(name args) (parse-slash line)]
    (if (not name)
        (events.emit {:type :error :error "empty command (try /help)"})
        (let [rec (. state.commands-extra name)]
          (if (not rec)
              (events.emit {:type :error
                            :error (.. "unknown command: /" name " (try /help)")})
              (and rec.idle-only? caller-state.busy?)
              (events.emit {:type :error
                            :error (.. "/" name
                                       " is disabled while the agent is running")})
              (let [(ok? err) (xpcall #(rec.handler args caller-state)
                                       debug.traceback)]
                (when (not ok?)
                  (events.emit {:type :error
                                :error (.. "/" name ": " (first-line err))
                                :traceback (tostring err)}))))))))

;; @doc fen.core.extensions.register.command.list
;; kind: function
;; signature: (list) -> [CommandInfo]
;; summary: Return command metadata used by help, docs, and diagnostics without exposing handler functions.
;; tags: extensions commands introspection
(fn M.list []
  (let [out []]
    (each [name rec (pairs state.commands-extra)]
      (table.insert out {:name name :owner rec.__owner
                         :description rec.description
                         :usage rec.usage
                         :subcommands rec.subcommands
                         :idle-only? rec.idle-only?
                         :order rec.order
                         :completes? (or (= (type rec.complete) :function)
                                         (not= rec.subcommands nil))}))
    out))

(fn descriptor-completions [descriptor]
  "Return subcommand choices from an optional presenter-agnostic descriptor."
  (let [out []]
    (when (and (= (type descriptor) :table)
               (= (type descriptor.subcommands) :table))
      (each [_ entry (ipairs descriptor.subcommands)]
        (table.insert out {:label (tostring entry.name)
                           :value (tostring entry.name)
                           :description (tostring (or entry.description ""))}))
      (when (not descriptor.has-help-subcommand?)
        (table.insert out {:label "help" :value "help"
                           :description "show this help"})))
    out))

;; @doc fen.core.extensions.register.command.arg-completions
;; kind: function
;; signature: (arg-completions name arg-prefix ctx) -> [Choice]
;; summary: Ask a registered command for argument completions via its optional :complete function, pcall-isolated.
;; tags: extensions commands completion
(fn M.arg-completions [name arg-prefix ctx]
  "Return argument-completion choices for command `name`.

   A command may expose an optional `:complete` function in its spec:
   `(complete arg-prefix ctx) -> [Choice]`, where each Choice is shaped
   `{:label str :value any :description str?}` (the same shape ui.select
   consumes). Returns an empty list when the command is unknown, has no
   completer, or the completer errors — completion must never crash input."
  (let [rec (. state.commands-extra name)]
    (if (and rec (= (type rec.complete) :function))
        (let [(ok? res) (pcall rec.complete arg-prefix ctx)]
          (if (and ok? (= (type res) :table)) res []))
        rec
        (descriptor-completions rec.subcommands)
        [])))

M
