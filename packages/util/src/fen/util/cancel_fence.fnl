;; Cancel fencing for holders outside the session lease: side chat turns,
;; headless session turns. Same contract as fen.core.tasks' holder id: every
;; acquire! takes a fresh id, a cancel names the id it was meant for, and a
;; cancel for an earlier holder never arms a later one
;; (spec/core/tasks/proofs/fence).
;;
;; The fence lives on the caller's table T (fields :fence-hid :fence-held?
;; :fence-cancel?), so it survives /reload with T; this module keeps no state.

(local M {})

;; @doc fen.util.cancel_fence.acquire!
;; kind: function
;; signature: (acquire! t) -> hid
;; summary: Start a new holder on T with a fresh id, not cancelled.
;; tags: util cancel
(fn M.acquire! [t]
  (let [hid (+ (or t.fence-hid 0) 1)]
    (set t.fence-hid hid)
    (set t.fence-held? true)
    (set t.fence-cancel? false)
    hid))

;; @doc fen.util.cancel_fence.release!
;; kind: function
;; signature: (release! t ?hid) -> nil
;; summary: Holder HID (default: the current one) is done; later cancels for it do nothing.
;; tags: util cancel
(fn M.release! [t ?hid]
  (when (or (= ?hid nil) (= ?hid t.fence-hid))
    (set t.fence-held? false)
    (set t.fence-cancel? false)))

;; @doc fen.util.cancel_fence.current
;; kind: function
;; signature: (current t) -> hid|nil
;; summary: The id of T's running holder, for a cancel control to capture.
;; tags: util cancel
(fn M.current [t]
  (when (= true t.fence-held?) t.fence-hid))

;; @doc fen.util.cancel_fence.cancel!
;; kind: function
;; signature: (cancel! t hid) -> ok?
;; summary: Arm cancellation of holder HID; does nothing unless HID still holds T.
;; tags: util cancel
(fn M.cancel! [t hid]
  (if (and (not= hid nil) (= hid (M.current t)))
      (do
        (set t.fence-cancel? true)
        true)
      false))

;; @doc fen.util.cancel_fence.cancel-current!
;; kind: function
;; signature: (cancel-current! t) -> ok?
;; summary: A cancel control: capture T's current holder and cancel! it.
;; tags: util cancel
(fn M.cancel-current! [t]
  (M.cancel! t (M.current t)))

;; @doc fen.util.cancel_fence.cancel-requested?
;; kind: function
;; signature: (cancel-requested? t hid) -> bool
;; summary: Whether cancel! armed holder HID and it still holds T.
;; tags: util cancel
(fn M.cancel-requested? [t hid]
  (and (= hid (M.current t)) (= true t.fence-cancel?)))

M
