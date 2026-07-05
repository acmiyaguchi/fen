{:name :provider_sakana
 :description "First-party Sakana AI provider (OpenAI-Responses-compatible Fugu models)."
 :enabled-by-default true
 :first-party? true
 :entry-module :fen.extensions.provider_sakana
 :reload-modules [:fen.extensions.provider_sakana.sakana_responses
                  :fen.extensions.provider_sakana]}
