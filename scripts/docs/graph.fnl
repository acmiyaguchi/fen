;; Graph/DOT helpers for generated maintainer diagrams.

(local M {})

(fn M.dot-escape [s]
  "Escape a string for use as a DOT quoted identifier/label."
  (let [s (tostring (or s ""))
        s (string.gsub s "\\" "\\\\")
        s (string.gsub s "\"" "\\\"")
        s (string.gsub s "\n" "\\n")]
    s))

(fn dot-quote [s]
  (.. "\"" (M.dot-escape s) "\""))

(fn sorted-keys [t]
  (let [out []]
    (each [k _ (pairs (or t {}))]
      (table.insert out k))
    (table.sort out (fn [a b] (< (tostring a) (tostring b))))
    out))

(fn render-attrs [attrs]
  (let [parts []]
    (each [_ k (ipairs (sorted-keys attrs))]
      (let [v (. attrs k)]
        (when (not= nil v)
          (table.insert parts (.. (tostring k) "=" (dot-quote v))))))
    (if (> (# parts) 0)
        (.. " [" (table.concat parts ", ") "]")
        "")))

(fn M.render-dot [name nodes edges]
  "Render a deterministic directed DOT graph.
   nodes: {id {:label ... :style ...}}, edges: [{:from :to :attrs {...}}]."
  (let [out [(.. "digraph " (tostring (or name "G")) " {")
             "  graph [rankdir=LR];"
             "  node [shape=box, fontname=\"monospace\"];"
             "  edge [fontname=\"monospace\"];"]]
    (each [_ id (ipairs (sorted-keys nodes))]
      (let [attrs (or (. nodes id) {})]
        (table.insert out (.. "  " (dot-quote id) (render-attrs attrs) ";"))))
    (let [sorted-edges []]
      (each [_ e (ipairs (or edges []))]
        (table.insert sorted-edges e))
      (table.sort sorted-edges
                  (fn [a b]
                    (let [aa (.. (tostring a.from) "\0" (tostring a.to) "\0" (tostring (or a.kind "")))
                          bb (.. (tostring b.from) "\0" (tostring b.to) "\0" (tostring (or b.kind "")))]
                      (< aa bb))))
      (each [_ e (ipairs sorted-edges)]
        (table.insert out (.. "  " (dot-quote e.from) " -> " (dot-quote e.to)
                              (render-attrs (or e.attrs {})) ";"))))
    (table.insert out "}")
    (table.concat out "\n")))

(fn adjacency [nodes edges]
  (let [adj {}]
    (each [_ id (ipairs nodes)]
      (tset adj id []))
    (each [_ e (ipairs edges)]
      (when (and (. adj e.from) (. adj e.to))
        (table.insert (. adj e.from) e.to)))
    adj))

(fn M.scc [nodes edges]
  "Return strongly-connected components with more than one node, using Tarjan."
  (let [adj (adjacency nodes edges)
        index-by {}
        lowlink {}
        on-stack {}
        stack []
        comps []]
    (var index 0)
    (var strongconnect nil)
    (set strongconnect
         (fn [v]
           (set index (+ index 1))
           (tset index-by v index)
           (tset lowlink v index)
           (table.insert stack v)
           (tset on-stack v true)
           (each [_ w (ipairs (or (. adj v) []))]
             (if (not (. index-by w))
                 (do
                   (strongconnect w)
                   (tset lowlink v (math.min (. lowlink v) (. lowlink w))))
                 (. on-stack w)
                 (tset lowlink v (math.min (. lowlink v) (. index-by w)))))
           (when (= (. lowlink v) (. index-by v))
             (let [comp []]
               (var done? false)
               (while (not done?)
                 (let [w (table.remove stack)]
                   (tset on-stack w nil)
                   (table.insert comp w)
                   (when (= w v) (set done? true))))
               (when (> (# comp) 1)
                 (table.sort comp)
                 (table.insert comps comp))))))
    (each [_ v (ipairs nodes)]
      (when (not (. index-by v))
        (strongconnect v)))
    comps))

(fn M.set-from-list [xs]
  (let [out {}]
    (each [_ x (ipairs (or xs []))]
      (tset out x true))
    out))

{:dot-escape M.dot-escape
 :render-dot M.render-dot
 :scc M.scc
 :set-from-list M.set-from-list}
