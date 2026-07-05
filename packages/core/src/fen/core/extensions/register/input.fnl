;; Input-handler kind. An ordered pipeline for non-slash user input.
;;
;; Presenters/main dispatch raw user input through `handle` before starting a
;; turn. Handlers run in ascending `:order` and may transform the input, consume
;; it, or resolve it into a structured orchestration action (start a turn, queue
;; steering/follow-up, report an error). This is deliberately NOT the event bus:
;; `events.emit` is notification-oriented and ignores return values, which makes
;; it a poor fit for ordered input transforms/intercepts. Handlers here return
;; structured actions the runtime acts on.
;;
;; The steering extension registers the default/fallback handler at a late order
;; (1000) so other extensions (macro expansion, planners, subagent routing) can
;; run before it. See issue #53.

(local state (require :fen.core.extensions.state))
(local util (require :fen.core.extensions.util))

(local M {})

(fn handlers []
  ;; `fen.core.extensions.state` is persistent across /reload. When this module
  ;; first lands in an already-running dev session, the long-lived state table
  ;; may not yet have the new bucket from state.fnl, so initialize it lazily.
  (when (= state.input-handlers nil)
    (set state.input-handlers []))
  state.input-handlers)

;; @doc fen.core.extensions.register.input.register
;; kind: function
;; signature: (register spec owner handle-result) -> register-result
;; summary: Validate and append an ordered input handler contribution consulted before non-slash user input starts a turn.
;; tags: extensions register input
(fn M.register [spec owner handle-result]
  (when (or (not spec) (not spec.name))
    (error "register :input-handler requires {:name ...}"))
  (when (not= (type spec.handle) :function)
    (error "register :input-handler requires {:handle fn}"))
  (let [spec* (util.deep-copy spec)]
    (when (= spec*.order nil) (set spec*.order 100))
    (let [(record unregister) (util.add-tagged! (handlers) spec* owner)]
      (handle-result :input-handler spec.name owner unregister))))

;; @doc fen.core.extensions.register.input.unregister-by-owner
;; kind: function
;; signature: (unregister-by-owner owner) -> nil
;; summary: Remove all input handlers installed by owner during extension reload or teardown.
;; tags: extensions register input reload
(fn M.unregister-by-owner [owner]
  (util.remove-where (handlers)
                     (fn [h _] (= h.__owner owner))))

(fn by-order [a b]
  (let [ao (or a.order 100)
        bo (or b.order 100)]
    (if (not= ao bo) (< ao bo)
        (not= (tostring (or a.__owner "")) (tostring (or b.__owner "")))
        (< (tostring (or a.__owner "")) (tostring (or b.__owner "")))
        (< (tostring (or a.name "")) (tostring (or b.name ""))))))

(fn ordered []
  (let [out []]
    (each [_ rec (ipairs (handlers))]
      (table.insert out rec))
    (table.sort out by-order)
    out))

;; @doc fen.core.extensions.register.input.list
;; kind: function
;; signature: (list) -> [InputHandlerInfo]
;; summary: Return input handlers sorted by order/owner/name without exposing handler functions.
;; tags: extensions input introspection
(fn M.list []
  (let [out []]
    (each [_ rec (ipairs (ordered))]
      (table.insert out {:name rec.name :owner rec.__owner :order rec.order}))
    out))

;; @doc fen.core.extensions.register.input.handle
;; kind: function
;; signature: (handle input ctx) -> action
;; summary: Run registered input handlers in ascending order, threading transformed input and returning the first resolving action.
;; tags: extensions input dispatch
(fn M.handle [input ctx]
  "Dispatch `input` through registered handlers in ascending :order.

   `input` is {:kind :user-input :text string}. `ctx` is a small
   runtime-owned table, currently {:busy? bool :state runtime-state}.

   Each handler returns a structured action:
     {:action :continue :input modified-input}  ; pass transformed input on
     {:action :consumed}                          ; swallow input, no turn
     {:action :start :text text}                  ; start a new turn
     {:action :queued :queue :steering|:follow-up :text text}
     {:action :error :error message}
     {:action :ignore}                            ; explicit no-op, stop chain

   The first non-continue/non-ignore action wins. If every handler passes,
   the input is returned as an implicit {:action :continue :input input} so the
   caller can decide a default (start a turn)."
  (var current input)
  (var result nil)
  (let [handlers (ordered)]
    (each [_ rec (ipairs handlers) &until result]
      (let [(ok? action) (pcall rec.handle current (or ctx {}))]
        (if (not ok?)
            ;; A misbehaving handler must not wedge input; skip it.
            nil
            (or (= (type action) :nil) (= (type action) :boolean))
            nil
            (= action.action :continue)
            (when (and action.input (= (type action.input) :table))
              (set current action.input))
            (= action.action :ignore)
            ;; Explicit no-op; stop the chain so ignored input is not later
            ;; started by the fallback handler.
            (set result action)
            ;; Any resolving action stops the chain.
            (set result action)))))
  (or result {:action :continue :input current}))

M
