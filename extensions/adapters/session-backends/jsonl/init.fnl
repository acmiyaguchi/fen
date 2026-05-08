;; First-party JSONL session backend wrapper.

(local session (require :fen.extensions.session_jsonl.session))

(local M {})

(fn M.register [api]

(api.register
  :session-backend
  {:name :jsonl
   :description "Append-only JSONL session backend under XDG state. Records canonical messages, replayable via --continue / /resume."
   :open (fn [cwd] (session.open cwd))
   :open-existing (fn [ref] (session.open-existing ref))
   :append (fn [handle msg] (session.append handle msg))
   :close (fn [handle] (session.close handle))
   :load (fn [ref] (session.load ref))
   :find (fn [cwd target] (session.find cwd target))
   :list (fn [cwd limit] (session.list-for-cwd cwd limit))
   :latest (fn [cwd] (session.latest-for-cwd cwd))
   :info (fn [handle]
           (when handle
             {:backend :jsonl
              :id handle.id
              :path handle.path
              :cwd handle.cwd}))})

  true)

M
