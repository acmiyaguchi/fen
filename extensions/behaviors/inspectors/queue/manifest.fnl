{:name :queue
 :description "Queue inspector: /queue, /cancel-all, and queue panel."
 :enabled-by-default true
 :first-party? true
 :entry-module :fen.extensions.queue
 :reload-modules [:fen.extensions.queue.util
                  :fen.extensions.queue.commands.queue
                  :fen.extensions.queue]}
