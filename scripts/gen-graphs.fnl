#!/usr/bin/env fennel
;; Generate Graphviz/DOT maintainer graphs.

(local fennel (require :fennel))
(set fennel.path
     (.. fennel.path
         ";./scripts/?.fnl;./scripts/?/init.fnl"
         ";./packages/core/src/?.fnl;./packages/core/src/?/init.fnl"))

(local scanner (require :docs.scanner))
(local graph (require :docs.graph))

(local OUT-DIR "docs/generated/graphs")

(fn write-file [path text]
  (os.execute (.. "mkdir -p " (string.match path "^(.+)/[^/]+$")))
  (let [f (assert (io.open path :w))]
    (f:write text)
    (f:close)))

(fn shell-quote [s]
  (.. "'" (string.gsub (tostring s) "'" "'\\''") "'"))

(fn command-ok? [cmd]
  (let [ok (os.execute cmd)]
    (or (= ok true) (= ok 0))))

(fn render-svg [dot-path svg-path]
  "Render DOT to SVG when Graphviz's dot is available."
  (if (command-ok? "command -v dot >/dev/null 2>&1")
      (let [cmd (.. "dot -Tsvg " (shell-quote dot-path) " -o " (shell-quote svg-path))]
        (if (command-ok? cmd)
            (print (.. "wrote " svg-path))
            (do
              (io.stderr:write (.. "warning: failed to render " svg-path "\n"))
              false)))
      (do
        (io.stderr:write "warning: Graphviz dot not found; skipped SVG rendering\n")
        false)))

(fn read-file [path]
  (let [f (assert (io.open path :r))
        data (f:read :*a)]
    (f:close)
    data))

(fn starts-with? [s prefix]
  (= (string.sub (tostring s) 1 (# prefix)) prefix))

(fn parse-reloadable []
  "Read packages/fen/src/fen/main.fnl's RELOADABLE vector as source of truth."
  (let [text (read-file "packages/fen/src/fen/main.fnl")
        start (string.find text "%(local%s+RELOADABLE%s+%[")
        out []]
    (when start
      (let [finish (or (string.find text "%]%)" start) (# text))
            body (string.sub text start finish)]
        (each [m (string.gmatch body ":([%w%._%-]+)")]
          (when (starts-with? m "fen.")
            (table.insert out m)))))
    out))

(fn module-nodes [tree]
  (let [nodes {}
        source-mods {}]
    (each [_ file (ipairs tree.files)]
      (let [mi file.module-info]
        (when mi
          (tset source-mods mi.module true)
          (tset nodes mi.module {:label mi.module
                                 :tooltip file.path
                                 :style :filled
                                 :fillcolor :white}))))
    (values nodes source-mods)))

(fn edge-key [from to kind]
  (.. from "\0" to "\0" (or kind "")))

(fn build-module-graph []
  (let [tree (scanner.scan-tree)
        agg (scanner.aggregate tree)
        (nodes source-mods) (module-nodes tree)
        reloadable (graph.set-from-list (parse-reloadable))
        edges []
        seen-edges {}]
    (each [_ dep (ipairs agg.dependencies)]
      (when (and dep.from dep.module (starts-with? dep.module "fen."))
        (when (not (. nodes dep.module))
          (tset nodes dep.module {:label dep.module
                                  :style :dashed
                                  :color :gray
                                  :fontcolor :gray}))
        (let [k (edge-key dep.from dep.module dep.kind)]
          (when (not (. seen-edges k))
            (tset seen-edges k true)
            (table.insert edges {:from dep.from
                                 :to dep.module
                                 :kind dep.kind
                                 :attrs {:label (tostring dep.kind)}})))))
    ;; Reloadability annotations.
    (each [id attrs (pairs nodes)]
      (if (. reloadable id)
          (do
            (tset attrs :fillcolor :palegreen)
            (tset attrs :tooltip (.. (or attrs.tooltip "") " reloadable")))
          (. source-mods id)
          (do
            (tset attrs :fillcolor :lightyellow)
            (tset attrs :tooltip (.. (or attrs.tooltip "") " persistent")))))
    ;; Cycle annotations over source/internal modules only.
    (let [source-list []
          source-edges []
          in-cycle {}
          cycle-edge {}]
      (each [id _ (pairs source-mods)]
        (table.insert source-list id))
      (table.sort source-list)
      (each [_ e (ipairs edges)]
        (when (and (. source-mods e.from) (. source-mods e.to))
          (table.insert source-edges e)))
      (let [comps (graph.scc source-list source-edges)]
        (each [_ comp (ipairs comps)]
          (let [members (graph.set-from-list comp)]
            (io.stderr:write (.. "cycle: " (table.concat comp " -> ") "\n"))
            (each [_ id (ipairs comp)]
              (tset in-cycle id true))
            (each [_ e (ipairs source-edges)]
              (when (and (. members e.from) (. members e.to))
                (tset cycle-edge (edge-key e.from e.to e.kind) true))))))
      (each [id _ (pairs in-cycle)]
        (let [attrs (. nodes id)]
          (tset attrs :color :red)
          (tset attrs :penwidth "2")))
      (each [_ e (ipairs edges)]
        (when (. cycle-edge (edge-key e.from e.to e.kind))
          (tset e.attrs :color :red)
          (tset e.attrs :penwidth "2"))))
    (graph.render-dot "fen_modules" nodes edges)))

(fn usage []
  (io.stderr:write "usage: fennel scripts/gen-graphs.fnl [--kind modules|all]\n")
  (os.exit 2))

(fn arg-value [args flag default]
  (var out default)
  (var i 1)
  (while (<= i (# args))
    (if (= (. args i) flag)
        (do
          (set out (. args (+ i 1)))
          (set i (+ i 2)))
        (set i (+ i 1))))
  out)

(let [kind (arg-value arg "--kind" "all")]
  (if (or (= kind "modules") (= kind "all"))
      (do
        (let [path (.. OUT-DIR "/modules.dot")
              svg-path (.. OUT-DIR "/modules.svg")]
          (write-file path (.. (build-module-graph) "\n"))
          (print (.. "wrote " path))
          (render-svg path svg-path)))
      (usage)))
