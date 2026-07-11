{:name :profiler
 :description "Opt-in Lua instruction-sampling profiler with Speedscope and folded flame-graph exports via /profile"
 :entry-module :fen.extensions.profiler
 :reload-modules [:fen.extensions.profiler.export
                  :fen.extensions.profiler.commands
                  :fen.extensions.profiler]
 :reload-exclude [:fen.extensions.profiler.state]}
