{:name :session_jsonl
 :description "JSONL session backend"
 :enabled-by-default true
 :first-party? true
 :entry-module :fen.extensions.session_jsonl
 :reload-modules [:fen.extensions.session_jsonl
                  :fen.extensions.session_jsonl.session]}
