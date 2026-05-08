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

(fn command-lines [cmd]
  (let [p (assert (io.popen cmd :r))
        out []]
    (each [line (p:lines)]
      (table.insert out line))
    (p:close)
    out))

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

(fn subsystem-for [mod]
  "Collapse a module id to a docs-facing subsystem bucket."
  (let [m (tostring mod)]
    (if (= m "fen.main") "cli"
        (= m "fen.version") "cli"
        (starts-with? m "fen.testing") "testing"
        (let [ext (string.match m "^fen%.extensions%.([%w_%-]+)")]
          (if ext (.. "extension." ext)
              (starts-with? m "fen.core.extensions") "core.extensions"
              (starts-with? m "fen.core.llm") "core.llm"
              (starts-with? m "fen.core") "core"
              (starts-with? m "fen.util.http") "util.http"
              (starts-with? m "fen.util") "util"
              "other")))))

(fn subsystem-label [sid]
  (if (= sid "cli") "CLI"
      (= sid "core") "core"
      (= sid "core.llm") "core.llm"
      (= sid "core.extensions") "core.extensions"
      (= sid "util") "util"
      (= sid "util.http") "util.http"
      (= sid "testing") "testing"
      (let [ext (string.match sid "^extension%.(.+)$")]
        (if ext (.. "extension: " ext) sid))))

(fn build-clusters [nodes]
  (let [clusters {}]
    (each [id _ (pairs nodes)]
      (let [sid (subsystem-for id)]
        (when (not (. clusters sid))
          (tset clusters sid {:label (subsystem-label sid) :nodes []}))
        (table.insert (. clusters sid :nodes) id)))
    clusters))

(fn source-node! [nodes id path label]
  (when (not (. nodes id))
    (tset nodes id {:label label
                    :tooltip path
                    :shape :component
                    :style :filled
                    :fillcolor :lightcyan})))

(fn external-node! [nodes id label]
  (when (not (. nodes id))
    (tset nodes id {:label label
                    :shape :ellipse
                    :style :dashed
                    :color :gray
                    :fontcolor :gray})))

(fn add-edge! [edges seen-edges from to kind attrs]
  (let [k (edge-key from to kind)]
    (when (not (. seen-edges k))
      (tset seen-edges k true)
      (table.insert edges {:from from
                           :to to
                           :kind kind
                           :attrs (or attrs {})}))))

(fn add-script-deps! [nodes edges seen-edges]
  "Add selected script/helper dependencies that are outside package modules."
  (each [_ path (ipairs (command-lines "find scripts -maxdepth 2 -type f \\( -name '*.fnl' -o -name '*.lua' \\) | sort"))]
    (let [text (read-file path)
          deps (scanner.scan-dependencies text)
          id (.. "script:" path)
          label (.. "script\n" path)]
      (var used? false)
      (each [_ dep (ipairs deps)]
        (when (starts-with? dep.module "fen.")
          (when (not used?)
            (source-node! nodes id path label)
            (set used? true))
          (when (not (. nodes dep.module))
            (external-node! nodes dep.module dep.module))
          (add-edge! edges seen-edges id dep.module :script-require
                     {:label :script})))))
  ;; scripts/busted-helper.lua uses Lua call syntax that the Fennel scanner
  ;; intentionally does not parse; keep the bootstrap dependency explicit.
  (let [path "scripts/busted-helper.lua"
        id (.. "script:" path)]
    (source-node! nodes id path (.. "script\n" path))
    (add-edge! edges seen-edges id "fen.util.flat_extensions" :lua-require
               {:label :lua})))

(fn add-c-bootstrap-deps! [nodes edges seen-edges]
  "Add C launcher/preload dependencies that static Fennel scanning cannot see."
  (let [path "packages/fen/fen.c"
        text (read-file path)
        id "c:packages/fen/fen.c"]
    (source-node! nodes id path "C launcher\npackages/fen/fen.c")
    (each [_ mod (ipairs ["fen.main" "fen.util.flat_extensions"])]
      (when (string.find text mod 1 true)
        (add-edge! edges seen-edges id mod :c-require {:label :c})))
    (each [_ mod (ipairs ["fennel" "cjson" "termbox2" "fen_http" "fen_process" "fen_random" "lfs"])]
      (when (string.find text (.. "\"" mod "\"") 1 true)
        (let [nid (.. "native:" mod)]
          (external-node! nodes nid mod)
          (add-edge! edges seen-edges id nid :c-preload {:label :preload}))))))

(fn collect-module-graph []
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
    (add-script-deps! nodes edges seen-edges)
    (add-c-bootstrap-deps! nodes edges seen-edges)
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
          cycle-edge {}
          cycles []]
      (each [id _ (pairs source-mods)]
        (table.insert source-list id))
      (table.sort source-list)
      (each [_ e (ipairs edges)]
        (when (and (. source-mods e.from) (. source-mods e.to))
          (table.insert source-edges e)))
      (let [comps (graph.scc source-list source-edges)]
        (each [_ comp (ipairs comps)]
          (let [members (graph.set-from-list comp)]
            (table.insert cycles comp)
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
          (tset e.attrs :penwidth "2")))
      (tset source-mods :__cycles cycles))
    {:nodes nodes :edges edges :source-mods source-mods :cycles (or source-mods.__cycles [])}))

(fn build-module-graph []
  (let [data (collect-module-graph)]
    (graph.render-dot "fen_modules" data.nodes data.edges)))

(fn build-clustered-module-graph []
  (let [data (collect-module-graph)]
    ;; Graphviz can struggle to route labels in the large clustered graph, so
    ;; keep this as a separate navigation aid and leave modules.svg as the
    ;; simpler full graph.
    (each [_ e (ipairs data.edges)]
      (if (= e.kind :macro)
          (set e.attrs {:style :dashed :color :gray50})
          (set e.attrs {})))
    (graph.render-dot-clustered "fen_modules_clustered" data.nodes data.edges (build-clusters data.nodes))))

(var write-graph! nil)

(fn sorted-pairs-by-count [counts]
  (let [items []]
    (each [id n (pairs counts)]
      (table.insert items {:id id :count n}))
    (table.sort items
                (fn [a b]
                  (if (= a.count b.count)
                      (< a.id b.id)
                      (> a.count b.count))))
    items))

(fn write-summary! []
  (let [data (collect-module-graph)
        fan-in {}
        fan-out {}
        out ["# Generated graph summary"
             ""
             "Generated by `scripts/gen-graphs.fnl`."
             ""
             "## Artifacts"
             ""
             "- `modules.dot` / `modules.svg` — full module dependency graph."
             "- `modules-clustered.dot` / `modules-clustered.svg` — same graph with subsystem clusters."
             "- `subsystems.dot` / `subsystems.svg` — collapsed subsystem graph."
             "- `extensions/*.dot` / `extensions/*.svg` — per-extension local graphs."
             ""
             "## Legend"
             ""
             "- pale green nodes: reloadable modules"
             "- light yellow nodes: persistent/source modules"
             "- light cyan component nodes: scripts or C/bootstrap sources"
             "- gray dashed ellipse nodes: external or native modules"
             "- red nodes/edges: strongly connected component membership"
             "- dashed gray edges: macro or clustered dynamic-ish edges"
             ""]]
    (each [_ e (ipairs data.edges)]
      (tset fan-out e.from (+ (or (. fan-out e.from) 0) 1))
      (tset fan-in e.to (+ (or (. fan-in e.to) 0) 1)))
    (table.insert out "## Cycles")
    (table.insert out "")
    (if (= (# data.cycles) 0)
        (table.insert out "No source-module cycles detected.")
        (each [_ comp (ipairs data.cycles)]
          (table.insert out (.. "- `" (table.concat comp "` → `") "`"))))
    (table.insert out "")
    (table.insert out "## Highest fan-in")
    (table.insert out "")
    (each [i item (ipairs (sorted-pairs-by-count fan-in))]
      (when (<= i 15)
        (table.insert out (.. "- `" item.id "`: " item.count))))
    (table.insert out "")
    (table.insert out "## Highest fan-out")
    (table.insert out "")
    (each [i item (ipairs (sorted-pairs-by-count fan-out))]
      (when (<= i 15)
        (table.insert out (.. "- `" item.id "`: " item.count))))
    (write-file (.. OUT-DIR "/summary.md") (.. (table.concat out "\n") "\n"))
    (print (.. "wrote " OUT-DIR "/summary.md"))))

(fn extension-slug [sid]
  (string.gsub (or (string.match sid "^extension%.(.+)$") sid) "_" "-"))

(fn dot-graph-id [s]
  (let [s (string.gsub (tostring s) "[^%w_]" "_")]
    (if (string.match s "^[%a_]") s (.. "g_" s))))

(fn build-extension-graphs []
  (let [data (collect-module-graph)
        by-ext {}]
    (each [id _ (pairs data.nodes)]
      (let [sid (subsystem-for id)]
        (when (string.match sid "^extension%.")
          (when (not (. by-ext sid))
            (tset by-ext sid true)))))
    (each [sid _ (pairs by-ext)]
      (let [nodes {}
            edges []]
        (each [id attrs (pairs data.nodes)]
          (when (= (subsystem-for id) sid)
            (tset nodes id attrs)))
        (each [_ e (ipairs data.edges)]
          (when (or (. nodes e.from) (. nodes e.to))
            (when (not (. nodes e.from))
              (tset nodes e.from (or (. data.nodes e.from) {:label e.from :style :dashed :color :gray})))
            (when (not (. nodes e.to))
              (tset nodes e.to (or (. data.nodes e.to) {:label e.to :style :dashed :color :gray})))
            (table.insert edges e)))
        (let [slug (extension-slug sid)]
          (write-graph! (.. "extensions/" slug)
                        (graph.render-dot (.. "fen_" (dot-graph-id slug)) nodes edges)))))))

(fn build-subsystem-graph []
  (let [data (collect-module-graph)
        nodes {}
        edges []
        counts {}
        seen-edges {}]
    (each [id _ (pairs data.nodes)]
      (let [sid (subsystem-for id)]
        (tset counts sid (+ (or (. counts sid) 0) 1))))
    (each [sid n (pairs counts)]
      (tset nodes sid {:label (.. (subsystem-label sid) "\n" n " modules")
                       :style :filled
                       :fillcolor (if (string.match sid "^extension%.") :lightyellow
                                      (or (= sid "core") (= sid "core.llm") (= sid "core.extensions")) :palegreen
                                      (= sid "cli") :lightblue
                                      :white)}))
    (each [_ e (ipairs data.edges)]
      (let [from (subsystem-for e.from)
            to (subsystem-for e.to)]
        (when (not= from to)
          (let [k (edge-key from to nil)]
            (when (not (. seen-edges k))
              (tset seen-edges k true)
              (table.insert edges {:from from :to to :attrs {}}))))))
    (graph.render-dot "fen_subsystems" nodes edges)))

(set write-graph!
     (fn [basename dot]
       (let [path (.. OUT-DIR "/" basename ".dot")
             svg-path (.. OUT-DIR "/" basename ".svg")]
         (write-file path (.. dot "\n"))
         (print (.. "wrote " path))
         (render-svg path svg-path))))

(fn usage []
  (io.stderr:write "usage: fennel scripts/gen-graphs.fnl [--kind modules|modules-clustered|subsystems|extensions|summary|all]\n")
  (os.exit 2))

(fn generate-kind! [kind]
  (if (= kind "modules")
      (write-graph! "modules" (build-module-graph))
      (= kind "modules-clustered")
      (write-graph! "modules-clustered" (build-clustered-module-graph))
      (= kind "subsystems")
      (write-graph! "subsystems" (build-subsystem-graph))
      (= kind "extensions")
      (build-extension-graphs)
      (= kind "summary")
      (write-summary!)
      (= kind "all")
      (do
        (write-graph! "modules" (build-module-graph))
        (write-graph! "modules-clustered" (build-clustered-module-graph))
        (write-graph! "subsystems" (build-subsystem-graph))
        (build-extension-graphs)
        (write-summary!))
      (usage)))

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
  (generate-kind! kind))
