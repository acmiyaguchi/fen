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
(local TRACKED-DIR "docs/graphs")

;; scan-tree walks and parses every source file (~1s); aggregate derives from it.
;; Both are pure over a stable on-disk tree within a single run, so cache them:
;; --kind all otherwise rescans ~7 times (once per collect-module-graph plus the
;; contribution graph). Callers never mutate the tree/agg they receive — they
;; only read it to build fresh node/edge tables — so sharing one copy is safe.
(var cached-tree nil)
(var cached-agg nil)

(fn scan-tree* []
  (when (not cached-tree)
    (set cached-tree (scanner.scan-tree)))
  cached-tree)

(fn aggregate* []
  (when (not cached-agg)
    (set cached-agg (scanner.aggregate (scan-tree*))))
  cached-agg)

(fn write-file [path text]
  (os.execute (.. "mkdir -p " (string.match path "^(.+)/[^/]+$")))
  (let [f (assert (io.open path :w))]
    (f:write text)
    (f:close)))

(fn shell-quote [s]
  (.. "'" (string.gsub (tostring s) "'" "'\\''") "'"))

(fn shallow-copy [t]
  (let [out {}]
    (each [k v (pairs t)]
      (tset out k v))
    out))

(fn command-ok? [cmd]
  (let [ok (os.execute cmd)]
    (or (= ok true) (= ok 0))))

;; SVG rendering is deferred: each graph writes its .dot synchronously and
;; queues the (dot, svg) pair, then flush-renders! runs every `dot` invocation
;; in parallel at the end. Rendering ~170 graphs one at a time dominated the
;; run; the renders are independent, so we fan them out across cores instead.
(var pending-renders [])

(fn queue-render! [dot-path svg-path]
  (table.insert pending-renders {:dot dot-path :svg svg-path}))

(fn flush-renders! []
  "Render all queued DOT->SVG jobs in parallel, capped at core count."
  (when (> (# pending-renders) 0)
    (if (not (command-ok? "command -v dot >/dev/null 2>&1"))
        (io.stderr:write "warning: Graphviz dot not found; skipped SVG rendering\n")
        (let [listfile (os.tmpname)
              f (assert (io.open listfile :w))]
          ;; DOT/SVG paths are slug-based with no whitespace, so a plain
          ;; space-separated list read by `read -r d s` is safe.
          (each [_ r (ipairs pending-renders)]
            (f:write (.. r.dot " " r.svg "\n")))
          (f:close)
          ;; POSIX sh: background `dot` jobs in batches of $maxj, waiting for
          ;; each batch before starting the next. Avoids bash-only `wait -n`.
          (let [cmd (.. "maxj=$(nproc 2>/dev/null || echo 4); n=0; "
                        "while read -r d s; do dot -Tsvg \"$d\" -o \"$s\" & "
                        "n=$((n+1)); [ \"$n\" -ge \"$maxj\" ] && { wait; n=0; }; "
                        "done < " (shell-quote listfile) "; wait")]
            (when (not (command-ok? cmd))
              (io.stderr:write "warning: some SVG renders failed\n"))
            (os.remove listfile)
            (print (.. "rendered " (# pending-renders) " SVGs")))))
    (set pending-renders [])))

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
  ;; scripts/test/busted-helper.lua uses Lua call syntax that the Fennel scanner
  ;; intentionally does not parse; keep the bootstrap dependency explicit.
  (let [path "scripts/test/busted-helper.lua"
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

(fn dep-attrs [kind]
  (if (= kind :late-require)
      {:label :late :style :dashed :color :gray50}
      (= kind :optional-require)
      {:label :optional :style :dotted :color :gray50}
      (= kind :macro)
      {:label :macro :style :dashed :color :gray50}
      {:label (tostring kind)}))

(fn collect-module-graph []
  (let [tree (scan-tree*)
        agg (aggregate*)
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
                                 :attrs (dep-attrs dep.kind)})))))
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
          load-source-edges []
          in-cycle {}
          cycle-edge {}
          cycles []
          dynamic-cycles []]
      (each [id _ (pairs source-mods)]
        (table.insert source-list id))
      (table.sort source-list)
      (each [_ e (ipairs edges)]
        (when (and (. source-mods e.from) (. source-mods e.to))
          (table.insert source-edges e)
          (when (not (or (= e.kind :late-require)
                         (= e.kind :optional-require)
                         (= e.kind :script-require)
                         (= e.kind :lua-require)
                         (= e.kind :c-require)
                         (= e.kind :c-preload)))
            (table.insert load-source-edges e))))
      (let [comps (graph.scc source-list load-source-edges)]
        (each [_ comp (ipairs comps)]
          (let [members (graph.set-from-list comp)]
            (table.insert cycles comp)
            (io.stderr:write (.. "cycle: " (table.concat comp " -> ") "\n"))
            (each [_ id (ipairs comp)]
              (tset in-cycle id true))
            (each [_ e (ipairs load-source-edges)]
              (when (and (. members e.from) (. members e.to))
                (tset cycle-edge (edge-key e.from e.to e.kind) true))))))
      (let [load-cycle-set {}]
        (each [_ comp (ipairs cycles)]
          (tset load-cycle-set (table.concat comp "\0") true))
        (each [_ comp (ipairs (graph.scc source-list source-edges))]
          (when (not (. load-cycle-set (table.concat comp "\0")))
            (table.insert dynamic-cycles comp))))
      (each [id _ (pairs in-cycle)]
        (let [attrs (. nodes id)]
          (tset attrs :color :red)
          (tset attrs :penwidth "2")))
      (each [_ e (ipairs edges)]
        (when (. cycle-edge (edge-key e.from e.to e.kind))
          (tset e.attrs :color :red)
          (tset e.attrs :penwidth "2")))
      (tset source-mods :__cycles cycles)
      (tset source-mods :__dynamic-cycles dynamic-cycles))
    {:nodes nodes
     :edges edges
     :source-mods source-mods
     :cycles (or source-mods.__cycles [])
     :dynamic-cycles (or source-mods.__dynamic-cycles [])}))

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
             "Generated by `scripts/docs/gen-graphs.fnl`."
             ""
             "## Artifacts"
             ""
             "- `docs/graphs/modules.dot` — tracked full module dependency graph."
             "- `docs/graphs/modules-clustered.dot` — tracked graph with subsystem clusters."
             "- `docs/graphs/subsystems.dot` — tracked collapsed subsystem graph."
             "- `docs/generated/graphs/contributions.dot` — ignored static extension contribution graph."
             "- `docs/generated/graphs/extensions/*.dot` — ignored per-extension local graphs."
             "- `docs/generated/graphs/modules/*.dot` — ignored per-module focused graphs for static HTML docs."
             "- SVG renderings are generated locally by `make graphs` but are not tracked."
             ""
             "## Legend"
             ""
             "- pale green nodes: reloadable modules"
             "- light yellow nodes: persistent/source modules"
             "- light cyan component nodes: scripts or C/bootstrap sources"
             "- gray dashed ellipse nodes: external or native modules"
             "- red nodes/edges: load-time strongly connected component membership"
             "- dashed gray edges: macro or late require edges"
             "- dotted gray edges: optional `pcall require` edges"
             ""]]
    (each [_ e (ipairs data.edges)]
      (tset fan-out e.from (+ (or (. fan-out e.from) 0) 1))
      (tset fan-in e.to (+ (or (. fan-in e.to) 0) 1)))
    (table.insert out "## Load-time cycles")
    (table.insert out "")
    (if (= (# data.cycles) 0)
        (table.insert out "No load-time source-module cycles detected.")
        (each [_ comp (ipairs data.cycles)]
          (table.insert out (.. "- `" (table.concat comp "` → `") "`"))))
    (table.insert out "")
    (table.insert out "## Late/optional cycles")
    (table.insert out "")
    (if (= (# data.dynamic-cycles) 0)
        (table.insert out "No additional late/optional source-module cycles detected.")
        (each [_ comp (ipairs data.dynamic-cycles)]
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

(fn clean-generated-graph-dir! [rel]
  "Remove stale DOT/SVG files in a generated graph subdirectory."
  (let [dir (.. OUT-DIR "/" rel)]
    (os.execute (.. "mkdir -p " (shell-quote dir)))
    (os.execute (.. "rm -f " (shell-quote dir) "/*.dot " (shell-quote dir) "/*.svg"))))

(fn clean-extension-graphs! []
  (clean-generated-graph-dir! "extensions"))

(fn module-slug [mod]
  (let [s (string.gsub (tostring mod) "[^%w_%-]+" "-")
        s (string.gsub s "^-+" "")
        s (string.gsub s "-+$" "")]
    (if (= s "") "module" s)))

(fn build-extension-graphs []
  (clean-extension-graphs!)
  (let [data (collect-module-graph)
        by-ext {}]
    (each [id _ (pairs data.nodes)]
      (let [sid (subsystem-for id)]
        (when (string.match sid "^extension%.")
          (when (not (. by-ext sid))
            (tset by-ext sid true)))))
    (each [sid _ (pairs by-ext)]
      (let [nodes {}
            edges []
            seen-edges {}]
        (each [id attrs (pairs data.nodes)]
          (when (= (subsystem-for id) sid)
            (tset nodes id attrs)))
        (each [_ e (ipairs data.edges)]
          (let [from-local? (. nodes e.from)
                to-local? (. nodes e.to)]
            (if (and from-local? to-local?)
                (add-edge! edges seen-edges e.from e.to e.kind e.attrs)
                from-local?
                (let [boundary-id (.. "external:" (subsystem-for e.to))]
                  (external-node! nodes boundary-id (.. "external\n" (subsystem-label (subsystem-for e.to))))
                  (add-edge! edges seen-edges e.from boundary-id :external-out
                             {:label (.. "out: " e.to) :style :dashed :color :gray50}))
                to-local?
                (let [boundary-id (.. "external:" (subsystem-for e.from))]
                  (external-node! nodes boundary-id (.. "external\n" (subsystem-label (subsystem-for e.from))))
                  (add-edge! edges seen-edges boundary-id e.to :external-in
                             {:label (.. "in: " e.from) :style :dashed :color :gray50})))))
        (let [slug (extension-slug sid)]
          (write-graph! (.. "extensions/" slug)
                        (graph.render-dot (.. "fen_" (dot-graph-id slug)) nodes edges)))))))

(fn contribution-node-id [r]
  (.. "contribution:" (tostring (or r.kind "unknown")) ":"
      (tostring (or r.name "dynamic")) ":"
      (tostring (or r.path "unknown")) ":"
      (tostring (or r.line 0))))

(fn extension-for-register-site [r]
  (let [mi (and r.path (scanner.module-from-path r.path))
        mod (?. mi :module)
        ext (and mod (string.match mod "^fen%.extensions%.([^%.]+)"))]
    (when ext
      {:name ext :module (.. "fen.extensions." ext)})))

(fn build-contribution-graph []
  "Build a static extension contribution graph from scanned api.register sites."
  (let [tree (scan-tree*)
        agg (aggregate*)
        nodes {}
        edges []
        seen-edges {}]
    (each [_ r (ipairs agg.register-sites)]
      (let [ext (extension-for-register-site r)]
        (when ext
          (let [ext-id (.. "extension:" ext.name)
                contrib-id (contribution-node-id r)
                name (tostring (or r.name "(dynamic)"))
                kind (tostring (or r.kind "unknown"))
                mi (scanner.module-from-path r.path)]
            (tset nodes ext-id {:label (.. "extension\n" ext.name)
                                :shape :folder
                                :style :filled
                                :fillcolor :lightyellow
                                :tooltip ext.module})
            (tset nodes contrib-id {:label (.. kind "\n" name)
                                    :shape :note
                                    :style :filled
                                    :fillcolor :white
                                    :tooltip (.. r.path ":" (tostring (or r.line "?")))})
            (add-edge! edges seen-edges ext-id contrib-id :register {:label :registers})
            (when mi
              (when (not (. nodes mi.module))
                (tset nodes mi.module {:label mi.module
                                       :shape :box
                                       :style :filled
                                       :fillcolor :palegreen
                                       :tooltip r.path}))
              (add-edge! edges seen-edges contrib-id mi.module :source {:label :source :style :dashed :color :gray50}))))))
    (graph.render-dot "fen_contributions" nodes edges)))

(fn build-module-focus-graphs []
  "Generate ignored per-module neighborhood graphs for static HTML module docs."
  (clean-generated-graph-dir! "modules")
  (let [data (collect-module-graph)
        source-mods data.source-mods]
    (each [focus _ (pairs source-mods)]
      (when (not (string.match (tostring focus) "^__"))
        (let [nodes {}
              edges []
              included {}]
          ;; Seed the focus module itself. (Note: `{[focus] true}` would key the
          ;; table by the sequence [focus], not the string focus — Fennel `[..]`
          ;; is a sequential constructor, not a Lua computed key.)
          (tset included focus true)
          ;; Include immediate dependencies and immediate dependents.
          (each [_ e (ipairs data.edges)]
            (when (or (= e.from focus) (= e.to focus))
              (tset included e.from true)
              (tset included e.to true)))
          ;; Copy each node's attrs so highlighting the focus below does not
          ;; mutate the shared attr tables in data.nodes (which would otherwise
          ;; leak the blue focus marker into every later graph).
          (each [id _ (pairs included)]
            (let [src (. data.nodes id)
                  attrs (if src (shallow-copy src) {:label id :style :dashed :color :gray})]
              (tset nodes id attrs)))
          (let [focus-attrs (. nodes focus)]
            (when focus-attrs
              (tset focus-attrs :color :blue)
              (tset focus-attrs :penwidth "3")))
          (each [_ e (ipairs data.edges)]
            (when (and (. included e.from) (. included e.to))
              (table.insert edges e)))
          (write-graph! (.. "modules/" (module-slug focus))
                        (graph.render-dot (.. "fen_module_" (dot-graph-id focus)) nodes edges)))))))

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
         (queue-render! path svg-path))))

(fn write-tracked-graph! [basename dot]
  "Write a tracked DOT artifact and ignored local SVG under docs/graphs."
  (let [dot-path (.. TRACKED-DIR "/" basename ".dot")
        svg-path (.. TRACKED-DIR "/" basename ".svg")]
    (write-file dot-path (.. dot "\n"))
    (print (.. "wrote " dot-path))
    (queue-render! dot-path svg-path)))

(fn usage []
  (io.stderr:write "usage: fennel scripts/docs/gen-graphs.fnl [--kind tracked|local|modules|modules-clustered|module-focus|subsystems|extensions|contributions|summary|all]\n")
  (os.exit 2))

(fn generate-tracked! []
  (write-tracked-graph! "modules" (build-module-graph))
  (write-tracked-graph! "modules-clustered" (build-clustered-module-graph))
  (write-tracked-graph! "subsystems" (build-subsystem-graph)))

(fn generate-local! []
  (write-graph! "contributions" (build-contribution-graph))
  (build-extension-graphs)
  (build-module-focus-graphs)
  (write-summary!))

(fn generate-kind! [kind]
  (if (= kind "tracked")
      (generate-tracked!)
      (= kind "local")
      (generate-local!)
      (= kind "modules")
      (write-tracked-graph! "modules" (build-module-graph))
      (= kind "modules-clustered")
      (write-tracked-graph! "modules-clustered" (build-clustered-module-graph))
      (= kind "module-focus")
      (build-module-focus-graphs)
      (= kind "subsystems")
      (write-tracked-graph! "subsystems" (build-subsystem-graph))
      (= kind "extensions")
      (build-extension-graphs)
      (= kind "contributions")
      (write-graph! "contributions" (build-contribution-graph))
      (= kind "summary")
      (write-summary!)
      (= kind "all")
      (do
        (generate-tracked!)
        (generate-local!))
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

(let [kind (arg-value arg "--kind" "tracked")]
  (generate-kind! kind)
  (flush-renders!))
