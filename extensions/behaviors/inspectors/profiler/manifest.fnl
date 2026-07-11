{:name :profiler
 :description "Opt-in Lua statistical profiler and flame-graph exporter"
 :entry-module :fen.extensions.profiler
 :reload-modules [:fen.extensions.profiler.export
                  :fen.extensions.profiler.commands
                  :fen.extensions.profiler]
 :reload-exclude [:fen.extensions.profiler.state]}
