;; Process-local file-mutation lock state. Not reloadable.
;;
;; `fen.util.file_mutex` is reloaded during /reload, but live owners and
;; waiters must retain this table's identity until they release their locks.

{:locks {}
 :canonical-cache {}
 :canonical-cache-size 0
 :canonical-cache-cwd nil}
