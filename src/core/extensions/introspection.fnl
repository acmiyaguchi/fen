(local state (require :core.extensions.state))
(local util (require :core.extensions.util))
(local prompt (require :core.extensions.prompt))

(local M {})

(fn M.record-extension! [name rec]
  "Record loader status for introspection."
  (tset state.extensions name rec)
  rec)

(fn list-event-handlers []
  (let [out {}]
    (each [event-name bucket (pairs state.handlers)]
      (let [entries []]
        (each [_ e (ipairs bucket)]
          (table.insert entries {:owner e.owner}))
        (tset out event-name entries)))
    out))

(fn list-prompt-contributions []
  (let [out {}]
    (each [_ slot (ipairs prompt.PROMPT-SLOTS)]
      (let [bucket (. state.prompt-fragments slot)
            entries []]
        (each [_ e (ipairs bucket)]
          (table.insert entries {:owner e.owner
                                 :dynamic? (= (type e.text-or-fn) :function)}))
        (tset out slot entries)))
    out))

(fn list-tools []
  (let [out []]
    (each [_ t (ipairs state.tools-extra)]
      (table.insert out {:name t.name :owner t.__owner}))
    out))

(fn list-commands []
  (let [out []]
    (each [name rec (pairs state.commands-extra)]
      (table.insert out {:name name :owner rec.owner
                         :description rec.description
                         :idle-only? rec.idle-only?
                         :order rec.order}))
    out))

(fn list-controls []
  (let [out []]
    (each [_ rec (ipairs (or state.controls-extra []))]
      (table.insert out {:name rec.name :owner rec.owner
                         :description rec.description
                         :keys rec.keys
                         :order rec.order}))
    out))

(fn list-presenters []
  (let [out []]
    (each [_ p (ipairs state.presenters)]
      (table.insert out {:name p.name :owner p.__owner :active? p.active?
                         :has-init? (= (type p.init) :function)
                         :has-run? (= (type p.run) :function)
                         :has-shutdown? (= (type p.shutdown) :function)}))
    out))

(fn list-extensions []
  (let [out []]
    (each [name rec (pairs state.extensions)]
      (table.insert out {:name name :status rec.status :path rec.path
                         :first-party? rec.first-party?}))
    out))

(fn M.list [kind]
  (let [data (if (= kind :tools) (list-tools)
                 (= kind :commands) (list-commands)
                 (= kind :controls) (list-controls)
                 (= kind :presenters) (list-presenters)
                 (= kind :extensions) (list-extensions)
                 (= kind :event-handlers) (list-event-handlers)
                 (= kind :system-prompt-contributions) (list-prompt-contributions)
                 (error (.. "unknown list kind: " (tostring kind))))]
    (util.freeze data)))

(fn M.describe-extension [name]
  (let [rec (. state.extensions name)]
    (if rec (util.freeze rec) nil)))

M
