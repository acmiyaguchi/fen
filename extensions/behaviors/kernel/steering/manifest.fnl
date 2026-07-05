{:name :steering
 :description "Steering/follow-up input pipeline handler and queue service consumed by the agent loop and queue commands."
 :enabled-by-default true
 :first-party? true
 :entry-module :fen.extensions.steering
 :reload-modules [:fen.extensions.steering.service
                  :fen.extensions.steering]
 :reload-exclude [:fen.extensions.steering.state]}
