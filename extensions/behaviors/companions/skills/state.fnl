;; Persistent UI/discovery state for the Agent Skills inspector panel.

{:visible? false
 :selected-name nil
 :cached-rows nil
 ;; Monotonic second counter (floor(monotonic-ms/1000)) captured when the
 ;; panel rows were last rendered; used for the per-second refresh tick, not a
 ;; wall-clock epoch.
 :cached-at 0
 :cached-w 0
 :cached-selected-name nil
 :discover-cache-key nil
 :discover-cache nil
 ;; Monotonic-ms reading captured when the discovery cache was last filled;
 ;; compared against DISCOVER-CACHE-TTL (ms) as an elapsed-duration TTL, not a
 ;; wall-clock epoch.
 :discover-cache-at 0}
