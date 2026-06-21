{:name :plan
 :description "Plan companion: draft, revise, inspect, and approve read-only execution plans."
 :enabled-by-default true
 :first-party? true
 :entry-module :fen.extensions.plan
 :reload-modules [:fen.extensions.plan]
 :reload-exclude [:fen.extensions.plan.state]}
