;; Persistent web-presenter state. Not listed in the web manifest's
;; reload-modules so browser clients/transcript survive /reload.

{:server nil
 :host "127.0.0.1"
 :port 8765
 :clients []
 :sse-clients []
 :pending-inputs []
 :quit? false
 :last-snapshot ""
 :last-broadcast 0
 :transcript []
 :status-info {:provider nil
               :model nil
               :last-input 0
               :steering-queued 0
               :follow-up-queued 0
               :running-label nil
               :thinking? false
               :cancelling? false
               :turn-start 0
               :spin-frame 0}}
