;; /docs: lightweight in-agent documentation browser.
;;
;; Runtime docs are sourced from live extension registries and the structured
;; fen.core.docs.contracts data module. Do not read docs/generated/*.md here:
;; those files are build/check artifacts, not part of the single-file runtime.

(local json (require :fen.util.json))
(local bitap (require :fen.util.search.bitap))
(local types (require :fen.core.types))
(local panel-state (require :fen.extensions.docs.state))

(local OWNER :docs)
(local M {})

(fn trim [s]
  (-> (or s "") (string.gsub "^%s+" "") (string.gsub "%s+$" "")))

(fn safe-json [v]
  (let [(ok? s) (pcall json.encode v)]
    (if ok? s (tostring v))))

(fn nth-arg [args n]
  (let [pat (.. (string.rep "%S+%s+" (- n 1)) "(%S+)")]
    (string.match (or args "") pat)))

(fn first-arg [args]
  (nth-arg args 1))

(fn rest-after-first [args]
  (string.match (or args "") "^%S+%s+(.+)$"))

(fn dim [text] {:text text :style :dim})
(fn heading [text] {:text text :style :assistant})

(local TOPICS
  [{:name :commands :source :runtime :kind :commands
    :summary "Registered slash commands."}
   {:name :tools :source :runtime :kind :tools
    :summary "Registered agent tools."}
   {:name :providers :source :runtime :kind :providers
    :summary "Registered LLM providers."}
   {:name :auth-backends :source :runtime :kind :auth-backends
    :summary "Registered auth backends."}
   {:name :session-backends :source :runtime :kind :session-backends
    :summary "Registered session persistence backends."}
   {:name :presenters :source :runtime :kind :presenters
    :summary "Registered interactive presenters."}
   {:name :controls :source :runtime :kind :controls
    :summary "Registered keyboard/UI controls."}
   {:name :status :source :runtime :kind :status
    :summary "Registered status-line items."}
   {:name :panels :source :runtime :kind :panels
    :summary "Registered presenter panels."}
   {:name :prompt-fragments :source :runtime :kind :prompt-fragments
    :summary "Registered system-prompt fragments."}
   {:name :introspectors :source :runtime :kind :introspectors
    :summary "Registered read-only extension snapshot providers."}
   {:name :events :source :contracts :key :events
    :summary "Event-bus shapes."}
   {:name :types :source :contracts :key :types
    :summary "Canonical message/tool types."}
   {:name :register-kinds :source :contracts :key :register-kinds
    :summary "Extension API register kinds."}
   {:name :interfaces :source :contracts :key :interfaces
    :summary "Provider/auth/session interface records."}
   {:name :extensions :source :runtime :kind :extensions
    :summary "Loaded/discovered extensions. See also /extensions."}])

(fn topic-name [topic] (tostring topic.name))

(fn find-topic [name]
  (let [wanted (string.lower (tostring (or name "")))]
    (var found nil)
    (each [_ topic (ipairs TOPICS)]
      (when (and (not found) (= (topic-name topic) wanted))
        (set found topic)))
    found))

(fn sorted-map-items [m]
  (let [items []]
    (each [k v (pairs (or m {}))]
      (table.insert items {:name k :value v}))
    (table.sort items (fn [a b] (< (tostring a.name) (tostring b.name))))
    items))

(fn count-map [m]
  (var n 0)
  (each [_ _ (pairs (or m {}))]
    (set n (+ n 1)))
  n)

(fn contract-data [topic]
  ;; Resolve at call/render time so /reload sees edits to contracts.fnl.
  (let [contracts (require :fen.core.docs.contracts)]
    (. contracts topic.key)))

(fn topic-count [topic]
  (if (= topic.source :runtime)
      (length (panel-state.api.list topic.kind))
      (count-map (contract-data topic))))

(fn entry-name [item]
  (tostring (or item.name item.id item.event item.kind item.owner "(unnamed)")))

(fn runtime-items [topic]
  (let [items []]
    (each [_ item (ipairs (panel-state.api.list topic.kind))]
      (table.insert items item))
    (table.sort items (fn [a b] (< (entry-name a) (entry-name b))))
    items))

(fn contract-items [topic]
  (let [items []]
    (each [_ item (ipairs (sorted-map-items (contract-data topic)))]
      (table.insert items {:name item.name :doc item.value}))
    items))

(fn topic-items [topic]
  (if (= topic.source :runtime)
      (runtime-items topic)
      (contract-items topic)))

(fn find-entry [topic name]
  (let [wanted (tostring (or name ""))]
    (var found nil)
    (each [_ item (ipairs (topic-items topic))]
      (when (and (not found) (= (entry-name item) wanted))
        (set found item)))
    found))

(fn fit [s w]
  (let [s (tostring (or s ""))]
    (if (> (length s) w)
        (if (> w 1) (.. (string.sub s 1 (- w 1)) "…") "…")
        s)))

(fn pad [s w]
  (let [s (fit s w)
        n (length s)]
    (.. s (string.rep " " (math.max 0 (- w n))))))

(fn box-top [w title]
  (let [head (.. "┌─ " title " ")
        head-cols (+ 4 (length title))
        fill-cols (math.max 0 (- w head-cols 1))]
    (.. head (string.rep "─" fill-cols) "┐")))

(fn box-bottom [w]
  (.. "└" (string.rep "─" (math.max 0 (- w 2))) "┘"))

(fn box-side [w text]
  (let [inner-w (math.max 0 (- w 4))
        text (or text "")
        n (length text)
        clipped (if (> n inner-w) (string.sub text 1 inner-w) text)
        pad (math.max 0 (- inner-w (length clipped)))]
    (.. "│ " clipped (string.rep " " pad) " │")))

(fn wrap-text [text width]
  (let [out []
        text (tostring (or text ""))
        width (math.max 1 width)]
    (var rest text)
    (while (> (length rest) width)
      (var cut width)
      (for [i width 1 -1]
        (when (and (= cut width) (= (string.sub rest i i) " "))
          (set cut i)))
      (if (<= cut 1)
          (do
            (table.insert out (string.sub rest 1 width))
            (set rest (string.sub rest (+ width 1))))
          (do
            (table.insert out (string.sub rest 1 (- cut 1)))
            (set rest (string.sub rest (+ cut 1))))))
    (table.insert out rest)
    out))

(fn bordered-rows [w content ?title]
  (let [out [{:text (box-top w (or ?title "docs")) :style :dim}]
        inner-w (math.max 1 (- w 4))]
    (each [_ row (ipairs content)]
      (each [_ line (ipairs (wrap-text row.text inner-w))]
        (table.insert out {:text (box-side w line) :style row.style})))
    (table.insert out {:text (box-bottom w) :style :dim})
    out))

(fn topic-index-rows []
  (let [rows [(heading "Docs")
              (dim "usage: /docs [topic] [name]")
              (dim "       /docs search <query>")
              (dim "topics:")]]
    (each [_ topic (ipairs TOPICS)]
      (table.insert rows
                    (dim (.. "  " (pad (topic-name topic) 18)
                             " " (pad (topic-count topic) 4)
                             " " topic.summary))))
    rows))

(fn runtime-summary [item]
  (or item.description item.summary item.label item.status item.api item.path ""))

(fn contract-summary [item]
  (or (?. item :doc :summary) ""))

(fn topic-rows [topic]
  (let [rows [(heading (.. "Docs: " (topic-name topic)))
              (dim topic.summary)
              (dim (.. "usage: /docs " (topic-name topic) " <name>"))]
        items (topic-items topic)]
    (if (= (length items) 0)
        (table.insert rows (dim "  (none)"))
        (each [_ item (ipairs items)]
          (table.insert rows
                        (dim (.. "  " (pad (entry-name item) 22)
                                 " " (if (= topic.source :runtime)
                                         (runtime-summary item)
                                         (contract-summary item)))))))
    rows))

(fn selected-rows []
  (let [topic (and panel-state.selected-topic (find-topic panel-state.selected-topic))]
    (if topic
        (topic-rows topic)
        (topic-index-rows))))

(fn panel-title []
  (if panel-state.selected-topic
      (.. "docs: " (tostring panel-state.selected-topic))
      "docs"))

(fn panel-rows [w]
  (let [now (os.time)]
    (when (or (not panel-state.cached-rows)
              (not= now panel-state.cached-at)
              (not= w panel-state.cached-w)
              (not= panel-state.selected-topic panel-state.cached-selected-topic)
              (not= panel-state.selected-name panel-state.cached-selected-name))
      (set panel-state.cached-rows (bordered-rows w (selected-rows) (panel-title)))
      (set panel-state.cached-at now)
      (set panel-state.cached-w w)
      (set panel-state.cached-selected-topic panel-state.selected-topic)
      (set panel-state.cached-selected-name panel-state.selected-name))
    panel-state.cached-rows))

(fn invalidate-cache! []
  (set panel-state.cached-rows nil)
  (set panel-state.cached-at 0)
  (set panel-state.cached-w 0)
  (set panel-state.cached-selected-topic nil)
  (set panel-state.cached-selected-name nil))

(fn panel-spec []
  {:name :docs
   :placement :above-input
   :order 55
   :height (fn [ctx]
             (if panel-state.visible?
                 (length (panel-rows (or (?. ctx :w) 80)))
                 0))
   :render (fn [ctx]
             (if panel-state.visible?
                 (panel-rows (or (?. ctx :w) 80))
                 []))})

(fn show-panel! [?topic]
  (panel-state.api.emit {:type :dismiss})
  (set panel-state.selected-topic (and ?topic (topic-name ?topic)))
  (set panel-state.selected-name nil)
  (set panel-state.visible? true)
  (invalidate-cache!)
  (panel-state.api.emit {:type :redraw})
  (panel-state.api.emit {:type :info
                    :text (if ?topic
                              (.. "docs panel: " (topic-name ?topic))
                              "docs panel: on")}))

(fn handle-toggle []
  (if panel-state.visible?
      (do (set panel-state.visible? false)
          (invalidate-cache!)
          (panel-state.api.emit {:type :info :text "docs panel: off"}))
      (show-panel! nil)))

(fn field-line [name f]
  (let [ty (or f.type (and f.const (.. "const " (tostring f.const))) "any")
        req (if f.required " required" "")
        summary (if f.summary (.. " — " f.summary) "")]
    (.. "- `:" (tostring name) "` `" ty "`" req summary)))

(fn append-contract-detail [lines item]
  (let [doc item.doc]
    (table.insert lines (.. "# " (entry-name item)))
    (table.insert lines "")
    (table.insert lines (or doc.summary ""))
    (when doc.enum
      (table.insert lines "")
      (table.insert lines (.. "Values: " (table.concat (icollect [_ v (ipairs doc.enum)] (tostring v)) ", "))))
    (when doc.variants
      (table.insert lines "")
      (table.insert lines (.. "Variants: " (table.concat (icollect [_ v (ipairs doc.variants)] (tostring v)) " | "))))
    (when doc.fields
      (table.insert lines "")
      (table.insert lines "Fields:")
      (each [_ f (ipairs (sorted-map-items doc.fields))]
        (table.insert lines (field-line f.name f.value))))
    (when doc.required-methods
      (table.insert lines "")
      (table.insert lines (.. "Required methods: " (table.concat (icollect [_ v (ipairs doc.required-methods)] (tostring v)) ", "))))
    (when doc.optional-methods
      (table.insert lines (.. "Optional methods: " (table.concat (icollect [_ v (ipairs doc.optional-methods)] (tostring v)) ", "))))))

(fn append-runtime-detail [lines topic item]
  (table.insert lines (.. "# " (topic-name topic) "/" (entry-name item)))
  (table.insert lines "")
  (when item.description
    (table.insert lines item.description)
    (table.insert lines ""))
  (each [_ k (ipairs [:owner :name :label :api :provider :model :status :path :source :kind :order :side :placement])]
    (when (. item k)
      (table.insert lines (.. "- `:" (tostring k) "`: " (tostring (. item k))))))
  (when item.parameters
    (table.insert lines "")
    (table.insert lines "Parameters:")
    (table.insert lines "```json")
    (table.insert lines (safe-json item.parameters))
    (table.insert lines "```"))
  (when item.reload-modules
    (table.insert lines (.. "- `:reload-modules`: " (safe-json item.reload-modules))))
  (when item.error
    (table.insert lines (.. "- `:error`: " (tostring item.error)))))

(fn detail-text [topic item]
  (let [lines []]
    (if (= topic.source :contracts)
        (append-contract-detail lines item)
        (append-runtime-detail lines topic item))
    (table.concat lines "\n")))

(fn contains-ci? [text query]
  (let [haystack (string.lower (tostring (or text "")))
        needle (string.lower (tostring (or query "")))]
    (and (not= needle "") (string.find haystack needle 1 true))))

(fn item-summary [topic item]
  (if (= topic.source :runtime)
      (runtime-summary item)
      (contract-summary item)))

(fn search-docs [query ?topic-filter]
  (let [hits []
        q (tostring (or query ""))
        matcher (bitap.compile q)
        wanted-topic (and ?topic-filter (not= ?topic-filter "") (string.lower (tostring ?topic-filter)))]
    (each [_ topic (ipairs TOPICS)]
      (when (or (not wanted-topic) (= (string.lower (topic-name topic)) wanted-topic))
        (each [_ item (ipairs (topic-items topic))]
          (let [summary (item-summary topic item)
                detail (detail-text topic item)
                label (.. (topic-name topic) "/" (entry-name item))
                haystack (table.concat [label summary detail] "\n")
                score (or (bitap.score matcher label)
                          (bitap.score matcher (.. label " " summary))
                          (and (contains-ci? haystack q) 1))]
            (when score
              (table.insert hits {:topic (topic-name topic)
                                  :name (entry-name item)
                                  :summary summary
                                  :score score}))))))
    (table.sort hits (fn [a b]
                       (if (= a.score b.score)
                           (< (.. a.topic "/" a.name) (.. b.topic "/" b.name))
                           (> a.score b.score))))
    hits))

(fn search-text [query hits]
  (let [lines [(.. "# Docs search: " (tostring query)) ""]]
    (if (= (length hits) 0)
        (table.insert lines "No matches.")
        (each [i hit (ipairs hits)]
          (when (<= i 50)
            (table.insert lines (.. "- `" hit.topic "/" hit.name "` " (or hit.summary ""))))))
    (when (> (length hits) 50)
      (table.insert lines (.. "- … " (- (length hits) 50) " more matches")))
    (table.concat lines "\n")))

(fn emit-detail! [topic item]
  (panel-state.api.emit {:type :assistant-text
                    :text (detail-text topic item)}))

(fn handle-topic [topic]
  (show-panel! topic))

(fn handle-detail [topic name]
  (let [item (find-entry topic name)]
    (if item
        (do
          (panel-state.api.emit {:type :dismiss})
          (set panel-state.selected-topic (topic-name topic))
          (set panel-state.selected-name (entry-name item))
          (set panel-state.visible? true)
          (invalidate-cache!)
          (emit-detail! topic item)
          (panel-state.api.emit {:type :redraw}))
        (panel-state.api.emit {:type :error
                          :error (.. "docs entry not found: "
                                     (topic-name topic) " " (tostring name))}))))

(fn text-result [_api text is-error?]
  {:content [(types.text-block (or text ""))]
   :is-error? (or is-error? false)})

(fn runtime-doc-record [item]
  (let [out {:name (entry-name item)}]
    (each [_ k (ipairs [:owner :label :description :summary :api :provider :model :status :path :source :kind :order :side :placement :parameters :reload-modules :error])]
      (when (. item k)
        (tset out k (. item k))))
    out))

(fn contract-doc-record [item]
  {:name (entry-name item) :doc item.doc})

(fn item-record [topic item]
  (if (= topic.source :contracts)
      (contract-doc-record item)
      (runtime-doc-record item)))

(fn topic-record [topic]
  {:name (topic-name topic)
   :summary topic.summary
   :count (topic-count topic)})

(fn topic-list-text []
  (table.concat (icollect [_ row (ipairs (topic-index-rows))] row.text) "\n"))

(fn topic-items-text [topic]
  (table.concat (icollect [_ row (ipairs (topic-rows topic))] row.text) "\n"))

(fn docs-tool-json [payload]
  (safe-json payload))

(fn docs-tool-execute [args _ctx api]
  (let [topic-arg (or args.topic "topics")
        name-arg args.name
        query-arg args.query
        format (or args.format :text)]
    (if (or (and query-arg (not= query-arg "")) (= topic-arg "search"))
        (let [query (or query-arg name-arg "")
              hits (search-docs query (and args.topic (not= topic-arg "search") topic-arg))
              payload {:query query :count (length hits) :hits hits}]
          (text-result api (if (= format :json) (docs-tool-json payload) (search-text query hits)) false))
        (= topic-arg "topics")
        (let [payload {:topics (icollect [_ topic (ipairs TOPICS)] (topic-record topic))}]
          (text-result api (if (= format :json) (docs-tool-json payload) (topic-list-text)) false))
        (let [topic (find-topic topic-arg)]
          (if (not topic)
              (text-result api (.. "error: unknown docs topic: " (tostring topic-arg)) true)
              (and name-arg (not= name-arg ""))
              (let [item (find-entry topic name-arg)]
                (if item
                    (text-result api
                                 (if (= format :json)
                                     (docs-tool-json {:topic (topic-name topic)
                                                      :entry (item-record topic item)})
                                     (detail-text topic item))
                                 false)
                    (text-result api (.. "error: docs entry not found: "
                                         (topic-name topic) " " (tostring name-arg)) true)))
              (let [items (topic-items topic)]
                (text-result api
                             (if (= format :json)
                                 (docs-tool-json {:topic (topic-record topic)
                                                  :items (icollect [_ item (ipairs items)]
                                                           (item-record topic item))})
                                 (topic-items-text topic))
                             false)))))))

;; @doc fen.extensions.docs.register
;; kind: function
;; signature: (register api?) -> true
;; summary: Register the /docs command, fen_docs tool, docs panel, and dismiss handler against the extension API.
;; tags: docs register command tool panel
(fn M.register [api]
  (set panel-state.api api)
  (api.register :command
    {:name :docs
     :order 35
     :description "Browse runtime docs: /docs [topic] [name]"
     :handler (fn [args _state]
                (let [args (trim args)]
                  (if (= args "")
                      (handle-toggle)
                      (let [topic-arg (first-arg args)
                            name-arg (nth-arg args 2)
                            topic (find-topic topic-arg)]
                        (if (= topic-arg "search")
                            (let [query (or (rest-after-first args) "")
                              hits (search-docs query)]
                              (panel-state.api.emit {:type :assistant-text
                                                :text (search-text query hits)}))
                            (not topic)
                            (panel-state.api.emit {:type :error
                                              :error (.. "unknown docs topic: " (tostring topic-arg))})
                            (and name-arg (not= name-arg ""))
                            (handle-detail topic name-arg)
                            (handle-topic topic))))))})
    (api.register :tool
      {:name :fen_docs
       :label "Fen Docs"
       :snippet "Read fen docs/contracts"
       :description "Read or search fen runtime docs and extension contracts. Useful for implementing extensions: inspect register kinds, canonical types, event shapes, and live commands/tools/providers. Topics: topics, commands, tools, providers, auth-backends, session-backends, presenters, controls, status, panels, prompt-fragments, introspectors, events, types, register-kinds, interfaces, extensions. Use name for a specific entry, e.g. {topic:'register-kinds', name:'tool'} or {topic:'types', name:'ToolResultMessage'}. Use query to search docs, optionally scoped by topic."
       :parameters {:type :object
                    :properties {:topic {:type :string
                                         :description "Docs topic. Use 'topics' to list available topics or 'search' with name/query to search all topics."}
                                 :name {:type :string
                                        :description "Optional entry name within the topic; for topic='search', the query string."}
                                 :query {:type :string
                                         :description "Search query. Searches all docs, or only the given topic when topic is set to a normal docs topic."}
                                 :format {:type :string
                                          :enum [:text :json]
                                          :description "Output format; defaults to text."}}
                    :required json.empty-array}
       :execute (fn [args ctx] (docs-tool-execute args ctx api))})
    ;; @doc register-site:panel:docs
    ;; summary: Runtime documentation browser panel backing the /docs command and fen_docs tool.
    ;; tags: panel docs commands
    (api.register :panel (panel-spec))

    (api.register :introspect
      {:name :panel
       :description "Current docs browser panel state and topic counts"
       :snapshot (fn [_]
                   {:visible? panel-state.visible?
                    :selected-topic panel-state.selected-topic
                    :selected-name panel-state.selected-name
                    :cached-w panel-state.cached-w
                    :cached-at panel-state.cached-at
                    :topic-count (length TOPICS)})})

    (api.on :dismiss
      (fn [ev]
        (when panel-state.visible?
          (set panel-state.visible? false)
          (invalidate-cache!)
          (when ev.announce?
            (panel-state.api.emit {:type :info :text "docs panel: off"})))))
  true)

M
