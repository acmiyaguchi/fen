(local state (require :core.extensions.state))
(local util (require :core.extensions.util))
(local events (require :core.extensions.events))

(local M {})

(fn M.register [spec owner handle-result]
  (when (or (not spec) (not spec.name) (not spec.handler))
    (error "register :command requires {:name :handler ...}"))
  (let [name spec.name
        record (util.deep-copy spec)]
    (tset record :owner owner)
    (tset state.commands-extra name record)
    (handle-result :command name owner
      (fn []
        (when (= (?. state.commands-extra name :owner) owner)
          (tset state.commands-extra name nil))))))

(fn M.unregister-by-owner [owner]
  (each [name rec (pairs state.commands-extra)]
    (when (= rec.owner owner)
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
              (let [(ok? err) (pcall rec.handler args caller-state)]
                (when (not ok?)
                  (events.emit {:type :error
                                :error (.. "/" name ": " (tostring err))}))))))))

(fn M.list []
  (let [out []]
    (each [name rec (pairs state.commands-extra)]
      (table.insert out {:name name :owner rec.owner
                         :description rec.description
                         :idle-only? rec.idle-only?
                         :order rec.order}))
    out))

M
