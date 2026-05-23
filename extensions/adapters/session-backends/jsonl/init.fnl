;; First-party JSONL session backend wrapper.

(local session (require :fen.extensions.session_jsonl.session))

(local M {})

(fn M.register [api]

(api.register
  :session-backend
  {:name :jsonl
   :description "Append-only JSONL session backend under XDG state. Records canonical messages, replayable via --continue / /resume."
   :open (fn [cwd] (session.open cwd))
   :open-existing (fn [ref ?yield-fn] (session.open-existing ref ?yield-fn))
   :append (fn [handle msg] (session.append handle msg))
   :append-entry (fn [handle entry] (session.append-entry handle entry))
   :close (fn [handle] (session.close handle))
   :load (fn [ref ?yield-fn] (session.load ref ?yield-fn))
   :find (fn [cwd target ?yield-fn] (session.find cwd target ?yield-fn))
   :list (fn [cwd limit ?yield-fn] (session.list-for-cwd cwd limit ?yield-fn))
   :latest (fn [cwd ?yield-fn] (session.latest-for-cwd cwd ?yield-fn))
   :info (fn [handle]
           (when handle
             {:backend :jsonl
              :id handle.id
              :path handle.path
              :cwd handle.cwd}))})

  true)

M
