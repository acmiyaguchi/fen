;; Persistent in-process metadata cache for the JSONL session backend.
;;
;; The JSONL files remain the source of truth. This table only avoids
;; repeatedly decoding unchanged transcript files during list/find/latest and
;; open-existing paths, and it intentionally survives /reload.
;;
;; :cache-cap and :cache-clock bound the cache with simple LRU semantics so a
;; long-lived TUI does not pin decoded metadata for hundreds of transcripts
;; (#426). The eviction policy lives in the reloadable session module; only the
;; data and the monotonic recency clock persist here.

{:record-cache {}
 :cache-cap 64
 :cache-clock 0}
