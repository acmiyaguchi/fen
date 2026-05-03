;; First-party JSONL session backend wrapper.

(local extensions (require :fen.core.extensions))
(local session (require :fen.extensions.session_jsonl.session))

(extensions.unregister-by-owner :session_jsonl)
(local api (extensions.make-api :session_jsonl))

(api.register
  :session-backend
  {:name :jsonl
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

true
