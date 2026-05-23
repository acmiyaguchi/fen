;; Persistent in-process metadata cache for the JSONL session backend.
;;
;; The JSONL files remain the source of truth. This table only avoids
;; repeatedly decoding unchanged transcript files during list/find/latest and
;; open-existing paths, and it intentionally survives /reload.

{:record-cache {}}
