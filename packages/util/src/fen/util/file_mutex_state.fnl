;; Non-reloadable lock state: live owners/waiters must retain this table's identity across /reload.

{:locks {}
 :canonical-cache {}
 :canonical-cache-size 0
 :canonical-cache-cwd nil}
