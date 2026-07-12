;; System-prompt fragments.

(local state (require :fen.core.extensions.state))
(local util (require :fen.core.extensions.util))
(local tokens (require :fen.util.tokens))

(local M {})

(fn next-seq! []
  (set state.prompt-next-seq (+ (or state.prompt-next-seq 0) 1))
  state.prompt-next-seq)

(fn order-for [opts]
  (let [raw (or opts.order 90)]
    (or (tonumber raw) 90)))

;; @doc fen.core.extensions.register.prompt.contribute
;; kind: function
;; signature: (contribute text-or-fn ?opts owner handle-result) -> register-result
;; summary: Append an ordered system-prompt fragment from api.prompt, tagging owner metadata and returning an unregister handle.
;; tags: extensions prompt register
(fn M.contribute [text-or-fn ?opts owner handle-result]
  (let [opts (or ?opts {})
        entry {:text-or-fn text-or-fn
               :__owner owner
               :id opts.id
               :title opts.title
               :description opts.description
               :order (order-for opts)
               :seq (next-seq!)}]
    (table.insert state.prompt-fragments entry)
    (handle-result :prompt-fragment (or opts.id :prompt) owner
      (fn []
        (util.remove-where state.prompt-fragments (fn [e _] (= e entry)))))))

;; @doc fen.core.extensions.register.prompt.unregister-by-owner
;; kind: function
;; signature: (unregister-by-owner owner) -> nil
;; summary: Remove all system-prompt fragments contributed by owner during reload or extension teardown.
;; tags: extensions prompt reload
(fn M.unregister-by-owner [owner]
  (util.remove-where state.prompt-fragments
                     (fn [e _] (= e.__owner owner))))

(fn render-fragment [entry ?ctx]
  (let [val entry.text-or-fn]
    (if (= (type val) :function)
        (let [(ok? result) (pcall val ?ctx)]
          (if ok?
              result
              (.. "<!-- extension "
                  (tostring entry.__owner)
                  " failed: "
                  (tostring result)
                  " -->")))
        val)))

(fn sorted-fragments []
  (let [out []]
    (each [_ entry (ipairs state.prompt-fragments)]
      (table.insert out entry))
    (table.sort out
      (fn [a b]
        (if (= a.order b.order)
            (< a.seq b.seq)
            (< a.order b.order))))
    out))

;; @doc fen.core.extensions.register.prompt.render
;; kind: function
;; signature: (render ?ctx) -> string|nil
;; summary: Render registered prompt fragments in final order, omitting nil/empty fragments and isolating fragment function errors.
;; tags: extensions prompt render
(fn M.render [?ctx]
  "Render all registered prompt fragments in numeric order. Fragment functions
   receive the prompt context table. Nil/empty fragments are omitted."
  (let [parts []]
    (each [_ entry (ipairs (sorted-fragments))]
      (let [rendered (render-fragment entry ?ctx)]
        (when (and rendered (not= rendered ""))
          (table.insert parts (tostring rendered)))))
    (if (= (length parts) 0)
        nil
        (table.concat parts "\n\n"))))

;; @doc fen.core.extensions.register.prompt.stats
;; kind: function
;; signature: (stats ?ctx) -> [PromptFragmentStat]
;; summary: Render each fragment in final order and report its byte size and approximate token count without exposing fragment text.
;; tags: extensions prompt introspection
(fn M.stats [?ctx]
  "Return per-fragment rendered-size metadata in final render order. Each entry
   carries owner/id/title/order/seq/dynamic? plus the rendered byte length and a
   rough token estimate. Fragment text itself is never returned. Nil/empty
   fragments report zero bytes so callers can see they contributed nothing."
  (let [out []
        parts []]
    (each [_ entry (ipairs (sorted-fragments))]
      (let [rendered (render-fragment entry ?ctx)
            text (if (and rendered (not= rendered "")) (tostring rendered) "")]
        (when (not= text "")
          (table.insert parts text))
        (table.insert out
          {:owner entry.__owner
           :id entry.id
           :title entry.title
           :order entry.order
           :seq entry.seq
           :dynamic? (= (type entry.text-or-fn) :function)
           :bytes (length text)
           :approx-tokens (tokens.approx-tokens text)})))
    (let [joined (if (= (length parts) 0) "" (table.concat parts "\n\n"))]
      (tset out :total-bytes (length joined))
      (tset out :total-approx-tokens (tokens.approx-tokens joined))
      (tset out :non-empty-count (length parts)))
    out))

(fn public-entry [e]
  {:owner e.__owner
   :id e.id
   :title e.title
   :description e.description
   :order e.order
   :seq e.seq
   :dynamic? (= (type e.text-or-fn) :function)})

;; @doc fen.core.extensions.register.prompt.list
;; kind: function
;; signature: (list) -> [PromptFragmentInfo]
;; summary: Return prompt-fragment metadata in final render order without exposing raw fragment text content.
;; tags: extensions prompt introspection
(fn M.list []
  "Return prompt fragments in final render order."
  (let [out []]
    (each [_ e (ipairs (sorted-fragments))]
      (table.insert out (public-entry e)))
    out))

M
