;; Repository-local maintainer command; it is intentionally not bundled.

(local overlay (require :fen.util.dev_overlay))
(local text (require :fen.util.text))

(fn [api]
  (api.register :command
    {:name :reload-from
     :order 31
     :description "Dev only: trust a fen worktree, switch source overlays, and reload"
     :idle-only? true
     :handler
     (fn [args state]
       (let [worktree (text.trim (or args ""))]
         (if (= worktree "")
             (api.emit {:type :error
                        :error "usage: /reload-from <fen-worktree>; this runs trusted code from that worktree"})
             (let [(roots err) (overlay.switch-worktree! worktree)]
               (if err
                   (api.emit {:type :error :error (.. "/reload-from: " err)})
                   (do
                     (api.emit {:type :assistant-text
                                :text (.. "reload-from> using trusted worktree " roots.worktree)})
                     ;; Reuse the normal path so core reload ordering,
                     ;; extension cleanup, presenter reinit, and agent rebuild
                     ;; remain exactly the established /reload contract.
                     (api.commands.dispatch "/reload --all" state)))))))})
  true)
