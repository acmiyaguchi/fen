;; First-party JSONL session backend wrapper.

(local session (require :fen.extensions.session_jsonl.session))

(local M {})

(fn M.register [api]

(api.register
  :session-backend
  {:name :jsonl
   :description "Append-only JSONL session backend under XDG state. Records canonical messages, replayable via --continue / /resume."
   :open (fn [cwd] (session.open cwd))
   :create (fn [cwd] (session.create cwd))
   :open-existing (fn [ref ?yield-fn] (session.open-existing ref ?yield-fn))
   :append (fn [handle msg] (session.append handle msg))
   :append-entry (fn [handle entry] (session.append-entry handle entry))
   :latest-extension-state
   (fn [handle extension ?yield-fn ?accept]
     (session.latest-extension-state handle extension ?yield-fn ?accept))
   :close (fn [handle] (session.close handle))
   :load (fn [ref ?yield-fn] (session.load ref ?yield-fn))
   :load-strict (fn [ref ?yield-fn] (session.load-strict ref ?yield-fn))
   :messages (fn [ref ?yield-fn] (session.transcript ref ?yield-fn))
   :messages-strict (fn [ref ?yield-fn] (session.transcript-strict ref ?yield-fn))
   :find (fn [cwd target ?yield-fn] (session.find cwd target ?yield-fn))
   :list (fn [cwd limit ?yield-fn] (session.list-for-cwd cwd limit ?yield-fn))
   :get (fn [cwd id ?yield-fn] (session.get cwd id ?yield-fn))
   :acquire-lock (fn [info] (session.acquire-lock info))
   :latest (fn [cwd ?yield-fn] (session.latest-for-cwd cwd ?yield-fn))
   :info (fn [handle]
           (when handle
             {:backend :jsonl
              :id handle.id
              :path handle.path
              :cwd handle.cwd}))})

  true)

M
