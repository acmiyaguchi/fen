(local json (require :fen.util.json))
(local path (require :fen.util.path))

(local M {})

(fn close! [handles p]
  (let [f (. handles p)]
    (when f
      (pcall #(f:close))
      (tset handles p nil))))

(fn M.append! [holder p rec warn]
  "Append rec to p, retaining a flushed handle in holder across calls."
  (let [handles (or holder.jsonl-handles {})]
    (when (= holder.jsonl-handles nil) (set holder.jsonl-handles handles))
    (let [(ok? err) (pcall
                      (fn []
                        (let [f (or (. handles p)
                                    (do
                                      (path.ensure-dir! (path.dirname p))
                                      (let [(opened open-err) (io.open p :a)]
                                        (if opened
                                            (do (tset handles p opened) opened)
                                            (error (tostring open-err))))))]
                          (f:write (.. (json.encode rec) "\n"))
                          ;; Flushing preserves durability/visibility while avoiding open/close per record.
                          (f:flush))))]
      (when (not ok?)
        (close! handles p)
        (warn (tostring err)))
      ok?)))

M
