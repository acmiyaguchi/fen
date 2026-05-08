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

(fn render-header [name]
  [(.. "digraph " (tostring (or name "G")) " {")
   "  graph [rankdir=LR, splines=false];"
   "  node [shape=box, fontname=\"monospace\"];"
   "  edge [fontname=\"monospace\"];"])

(fn sorted-edges [edges]
  (let [out []]
    (each [_ e (ipairs (or edges []))]
      (table.insert out e))
    (table.sort out
                (fn [a b]
                  (let [aa (.. (tostring a.from) "\0" (tostring a.to) "\0" (tostring (or a.kind "")))
                        bb (.. (tostring b.from) "\0" (tostring b.to) "\0" (tostring (or b.kind "")))]
                    (< aa bb))))
    out))

(fn render-edge-lines! [out edges indent]
  (each [_ e (ipairs (sorted-edges edges))]
    (table.insert out (.. indent (dot-quote e.from) " -> " (dot-quote e.to)
                          (render-attrs (or e.attrs {})) ";"))))

(fn M.render-dot [name nodes edges]
  "Render a deterministic directed DOT graph.
   nodes: {id {:label ... :style ...}}, edges: [{:from :to :attrs {...}}]."
  (let [out (render-header name)]
    (each [_ id (ipairs (sorted-keys nodes))]
      (let [attrs (or (. nodes id) {})]
        (table.insert out (.. "  " (dot-quote id) (render-attrs attrs) ";"))))
    (render-edge-lines! out edges "  ")
    (table.insert out "}")
    (table.concat out "\n")))

(fn dot-id [s]
  (let [s (string.gsub (tostring s) "[^%w_]" "_")]
    (if (string.match s "^[%a_]") s (.. "g_" s))))

(fn M.render-dot-clustered [name nodes edges clusters]
  "Render DOT with one-level Graphviz clusters.
   clusters: {id {:label ... :nodes [node-id ...]}}."
  (let [out (render-header name)
        clustered {}]
    (each [_ cid (ipairs (sorted-keys clusters))]
      (let [cluster (. clusters cid)
            node-ids []]
        (each [_ id (ipairs (or cluster.nodes []))]
          (when (. nodes id)
            (tset clustered id true)
            (table.insert node-ids id)))
        (when (> (# node-ids) 0)
          (table.sort node-ids)
          (table.insert out (.. "  subgraph cluster_" (dot-id cid) " {"))
          (table.insert out (.. "    label=" (dot-quote (or cluster.label cid)) ";"))
          (table.insert out "    style=rounded;")
          (table.insert out "    color=gray70;")
          (each [_ id (ipairs node-ids)]
            (table.insert out (.. "    " (dot-quote id) (render-attrs (or (. nodes id) {})) ";")))
          (table.insert out "  }"))))
    (each [_ id (ipairs (sorted-keys nodes))]
      (when (not (. clustered id))
        (table.insert out (.. "  " (dot-quote id) (render-attrs (or (. nodes id) {})) ";"))))
    (render-edge-lines! out edges "  ")
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
 :render-dot-clustered M.render-dot-clustered
 :scc M.scc
 :set-from-list M.set-from-list}
