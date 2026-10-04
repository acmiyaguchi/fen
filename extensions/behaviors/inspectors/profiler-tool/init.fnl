;; Explicit model-facing adapter for the default /profile inspector.
;;
;; This extension intentionally stays out of the embedded release manifest list.

(local M {})

(fn M.register [api]
  (api.register :tool
                {:name :profile
                 :label "Profile"
                 :exposure :search
                 :snippet "Control Lua instruction sampling"
                 :description "Control fen's statistical profiler for self-investigation. Actions: start, status, report, stop, reset, or save. Start accepts period (at least 100) and mode (functions or lines); tool save output-directory is confined to fen's profiles artifact root (or omit it to use an operator-configured default). Samples measure Lua VM instructions, not wall-clock time."
                 :parameters {:type :object
                              :properties {:action {:type :string
                                                    :enum ["start"
                                                           "status"
                                                           "report"
                                                           "mark"
                                                           "stop"
                                                           "reset"
                                                           "save"]}
                                           :mark {:type :string}
                                           :period {:type :integer
                                                    :minimum 100}
                                           :mode {:type :string
                                                  :enum ["functions" "lines"]}
                                           :output-directory {:type :string
                                                              :description "Optional relative directory below fen's profiles artifact root; absolute paths outside it and .. traversal are rejected. Omit to use the operator-configured default."}}
                              :required [:action]}
                 :execute (fn [args ctx]
                            ;; Resolve the reloadable command implementation for every call.
                            ((. (require :fen.extensions.profiler.commands)
                                :execute-tool) args ctx))})
  true)

M
