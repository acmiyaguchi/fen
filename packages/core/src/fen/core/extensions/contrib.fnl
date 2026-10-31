;; Per-owner contribution sets; every registry view is a fold over owners in load order (#673).
;; The store and ranks live on fen.core.extensions.state; the view tables keep their identity.

(local state (require :fen.core.extensions.state))
(local util (require :fen.core.extensions.util))

(local M {})

;; Bus subscriptions made without an owner share one pseudo-owner.
(local ANONYMOUS :__anonymous)

(fn owner-key [owner]
  (if (= owner nil) ANONYMOUS owner))

(fn ensure-hooks! []
  (when (= state.hooks nil)
    (set state.hooks {}))
  (when (= state.hooks.before-tool nil)
    (set state.hooks.before-tool []))
  state.hooks.before-tool)

(fn bucket-target [key]
  (fn []
    (when (= (. state key) nil)
      (tset state key {}))
    (. state key)))

(fn promote-ui-slot! [presenters]
  (set state.ui.slot nil)
  (each [_ p (ipairs presenters)]
    (when (and (not state.ui.slot) p.active? p.ui)
      (set state.ui.slot p.ui))))

(fn drop-stale-session-backend! [backends]
  ;; The cached implementation must be one the view still serves; resolution by active-name continues.
  (let [cached (?. state :session :backend)]
    (when cached
      (var live? false)
      (each [_ b (pairs backends) &until live?]
        (when (= b cached) (set live? true)))
      (when (not live?)
        (set state.session.backend nil)))))

(fn renumber-prompt! [fragments]
  ;; Ties on :order break by fold position, so a reload never reorders equal-order fragments.
  (each [i entry (ipairs fragments)]
    (set entry.seq i)))

;; shape :array concatenates owners in rank order; :dict lets a later owner win a key;
;; :buckets is a dict of arrays (the event bus).
(local VIEWS
       {:tools {:target (bucket-target :tools-extra) :shape :array}
        :commands {:target (bucket-target :commands-extra) :shape :dict}
        :controls {:target (bucket-target :controls-extra) :shape :array}
        :status {:target (bucket-target :status-extra) :shape :array}
        :panels {:target (bucket-target :panel-extra) :shape :array}
        :hooks {:target ensure-hooks! :shape :array}
        :input-handlers {:target (bucket-target :input-handlers) :shape :array}
        :presenters {:target (bucket-target :presenters)
                     :shape :array
                     :after promote-ui-slot!}
        :introspectors {:target (bucket-target :introspectors-extra)
                        :shape :array}
        :actions {:target (bucket-target :actions-extra) :shape :array}
        :providers {:target (bucket-target :providers) :shape :dict}
        :auth-backends {:target (bucket-target :auth-backends) :shape :dict}
        :session-backends {:target (bucket-target :session-backends)
                           :shape :dict
                           :after drop-stale-session-backend!}
        :prompt-fragments {:target (bucket-target :prompt-fragments)
                           :shape :array
                           :after renumber-prompt!}
        :handlers {:target (bucket-target :handlers) :shape :buckets}})

(local VIEW-ORDER [:tools
                   :commands
                   :controls
                   :status
                   :panels
                   :hooks
                   :input-handlers
                   :presenters
                   :introspectors
                   :actions
                   :providers
                   :auth-backends
                   :session-backends
                   :prompt-fragments
                   :handlers])

(fn ranks []
  (when (= state.contribution-ranks nil)
    (set state.contribution-ranks {}))
  state.contribution-ranks)

;; @doc fen.core.extensions.contrib.rank!
;; kind: function
;; signature: (rank! owner) -> number
;; summary: Return owner's fold position, assigning the next one on first sight; a rank is never reassigned, so a reload keeps the owner's place.
;; tags: extensions registry reload
(fn M.rank! [owner]
  (let [k (owner-key owner)
        r (ranks)]
    (or (. r k) (let [n (+ (or state.contribution-next-rank 0) 1)]
                  (set state.contribution-next-rank n)
                  (tset r k n)
                  n))))

;; @doc fen.core.extensions.contrib.reserve-order!
;; kind: function
;; signature: (reserve-order! owners) -> nil
;; summary: Rank not-yet-seen owners in the given (discovery) order, so a fresh start, a later enable, and a scoped reload fold owners identically.
;; tags: extensions registry loader
(fn M.reserve-order! [owners]
  (each [_ owner (ipairs (or owners []))]
    (M.rank! owner)))

(fn fresh-set [] {})

(fn add-to-set! [set* view key record]
  (let [entries (or (. set* view) [])]
    (table.insert entries {: key : record})
    (tset set* view entries)))

(fn adopt-existing! [store]
  "First use in a process that registered through the pre-#673 code: adopt
   what the views already hold, so the first rebuild drops nothing."
  (each [_ view (ipairs VIEW-ORDER)]
    (let [spec (. VIEWS view)
          target (spec.target)
          take! (fn [key record]
                  (when (= (type record) :table)
                    (let [k (owner-key record.__owner)]
                      (M.rank! record.__owner)
                      (when (= (. store k) nil)
                        (tset store k (fresh-set)))
                      (add-to-set! (. store k) view key record))))]
      (case spec.shape
        :array (each [_ record (ipairs target)] (take! nil record))
        :dict (each [key record (pairs target)] (take! key record))
        :buckets (each [key bucket (pairs target)]
                   (each [_ record (ipairs bucket)]
                     (take! key record)))))))

(fn store []
  (when (= state.contributions nil)
    (let [s {}]
      (adopt-existing! s)
      (set state.contributions s)))
  state.contributions)

(fn owners-in-order []
  (let [r (ranks)
        out []]
    (each [k _ (pairs (store))]
      (table.insert out k))
    (table.sort out
                (fn [a b]
                  (let [ra (or (. r a) math.huge)
                        rb (or (. r b) math.huge)]
                    (if (= ra rb) (< (tostring a) (tostring b)) (< ra rb)))))
    out))

(fn clear-array! [t]
  (for [i (length t) 1 -1]
    (table.remove t i)))

(fn clear-dict! [t]
  (let [keys []]
    (each [k _ (pairs t)]
      (table.insert keys k))
    (each [_ k (ipairs keys)]
      (tset t k nil))))

(fn rebuild-one! [view]
  (let [spec (. VIEWS view)
        target (spec.target)
        s (store)
        owners (owners-in-order)]
    (case spec.shape
      :array (do
               (clear-array! target)
               (each [_ k (ipairs owners)]
                 (each [_ e (ipairs (or (. s k view) []))]
                   (table.insert target e.record))))
      :dict (do
              (clear-dict! target)
              (each [_ k (ipairs owners)]
                (each [_ e (ipairs (or (. s k view) []))]
                  (tset target e.key e.record))))
      :buckets (let [fresh {}]
                 (each [_ k (ipairs owners)]
                   (each [_ e (ipairs (or (. s k view) []))]
                     (let [b (or (. fresh e.key) [])]
                       (table.insert b e.record)
                       (tset fresh e.key b))))
                 ;; Rebuild live buckets in place: an emit in progress checks membership on them.
                 (each [name bucket (pairs target)]
                   (clear-array! bucket)
                   (each [_ record (ipairs (or (. fresh name) []))]
                     (table.insert bucket record)))
                 (each [name records (pairs fresh)]
                   (when (= (. target name) nil)
                     (tset target name records)))))
    (when spec.after
      (spec.after target))))

(fn rebuild! [views]
  "Rebuild the named views (a set) and bump the registry version once."
  (var any? false)
  (each [_ view (ipairs VIEW-ORDER)]
    (when (. views view)
      (set any? true)
      (rebuild-one! view)))
  (when any?
    (util.bump-registry-version!)))

(fn views-of [set* ?into]
  (let [out (or ?into {})]
    (each [view entries (pairs (or set* {}))]
      (when (> (length entries) 0)
        (tset out view true)))
    out))

(fn unknown-view! [view]
  (error (.. "unknown contribution view: " (tostring view))))

(fn remove-entry! [owner view record]
  (let [k (owner-key owner)
        entries (?. (store) k view)]
    (var removed? false)
    (when entries
      (for [i (length entries) 1 -1]
        (when (= (. entries i :record) record)
          (table.remove entries i)
          (set removed? true))))
    (when removed?
      (rebuild! {view true}))))

;; @doc fen.core.extensions.contrib.add!
;; kind: function
;; signature: (add! owner view key record) -> (record, unregister-fn)
;; summary: Tag record with :__owner, add it to owner's contribution set, re-derive that view, and return an identity-scoped unregister closure.
;; tags: extensions registry
(fn M.add! [owner view key record]
  (when (not (. VIEWS view))
    (unknown-view! view))
  (tset record :__owner owner)
  (M.rank! owner)
  (let [s (store)
        k (owner-key owner)]
    (when (= (. s k) nil)
      (tset s k (fresh-set)))
    (add-to-set! (. s k) view key record)
    (rebuild! {view true})
    (values record (fn [] (remove-entry! owner view record)))))

;; @doc fen.core.extensions.contrib.remove-where!
;; kind: function
;; signature: (remove-where! owner view pred) -> nil
;; summary: Remove owner's entries in one view whose record matches pred, then re-derive the view.
;; tags: extensions registry
(fn M.remove-where! [owner view pred]
  (let [entries (?. (store) (owner-key owner) view)]
    (var removed? false)
    (when entries
      (for [i (length entries) 1 -1]
        (when (pred (. entries i :record))
          (table.remove entries i)
          (set removed? true))))
    (when removed?
      (rebuild! {view true}))))

;; @doc fen.core.extensions.contrib.drop-view!
;; kind: function
;; signature: (drop-view! owner view) -> nil
;; summary: Remove every contribution owner made to one view (for example its bus subscriptions) and re-derive it.
;; tags: extensions registry reload
(fn M.drop-view! [owner view]
  (let [set* (. (store) (owner-key owner))]
    (when (and set* (. set* view) (> (length (. set* view)) 0))
      (tset set* view nil)
      (rebuild! {view true}))))

;; @doc fen.core.extensions.contrib.drop!
;; kind: function
;; signature: (drop! owner) -> nil
;; summary: Remove owner's whole contribution set; the views re-derive, so a name another owner also claims resolves to that owner again.
;; tags: extensions registry reload
(fn M.drop! [owner]
  (let [s (store)
        k (owner-key owner)
        old (. s k)]
    (tset s k nil)
    (rebuild! (views-of old))))

;; @doc fen.core.extensions.contrib.begin!
;; kind: function
;; signature: (begin! owner) -> token
;; summary: Start staging a new version of owner: registrations land in a fresh set that the views show at once; commit! keeps it, rollback! restores the previous set.
;; tags: extensions registry reload
(fn M.begin! [owner]
  (let [s (store)
        k (owner-key owner)
        old (. s k)]
    (M.rank! owner)
    (tset s k (fresh-set))
    (rebuild! (views-of old))
    {: owner : old}))

;; @doc fen.core.extensions.contrib.commit!
;; kind: function
;; signature: (commit! token) -> nil
;; summary: Keep the staged set begun by begin!; the previous version's registrations are gone.
;; tags: extensions registry reload
(fn M.commit! [_token]
  nil)

;; @doc fen.core.extensions.contrib.rollback!
;; kind: function
;; signature: (rollback! token) -> nil
;; summary: Discard the staged set and restore the owner's previous contributions (none for a first load).
;; tags: extensions registry reload
(fn M.rollback! [token]
  (let [s (store)
        k (owner-key token.owner)
        staged (. s k)
        touched (views-of token.old (views-of staged))]
    (tset s k token.old)
    (rebuild! touched)))

;; @doc fen.core.extensions.contrib.owners
;; kind: function
;; signature: (owners) -> [owner]
;; summary: Return the owners that currently hold contributions, in fold order.
;; tags: extensions registry introspection
(fn M.owners []
  (let [out []]
    (each [_ k (ipairs (owners-in-order))]
      (when (not= k ANONYMOUS)
        (table.insert out k)))
    out))

;; @doc fen.core.extensions.contrib.reset!
;; kind: function
;; signature: (reset!) -> nil
;; summary: Forget every contribution set and rank (test isolation and explicit registry recovery); callers clear the view tables.
;; tags: extensions registry reload
(fn M.reset! []
  (set state.contributions {})
  (set state.contribution-ranks {})
  (set state.contribution-next-rank 0))

(fn M.promote-ui-slot! []
  "Select the ui table from the first active presenter in fold order."
  (promote-ui-slot! ((. VIEWS :presenters :target))))

M
