;; /profile controls for the opt-in statistical profiler.

(local state (require :fen.extensions.profiler.state))
(local export (require :fen.extensions.profiler.export))
(local types (require :fen.core.types))

(local M {})

(fn words [s]
  (let [out []]
    (each [word (string.gmatch (or s "") "%S+")]
      (table.insert out word))
    out))

(fn usage []
  (table.concat
    ["usage: /profile start [--period N] [--mode functions|lines]"
     "       /profile status|stop|reset|report"
     "       /profile save [output-directory]"
     "samples are Lua VM instruction-count samples, not wall-clock time"]
    "\n"))

(fn emit-info [api text]
  (api.emit {:type :info :source :profiler :text text}))

(fn emit-error [api text]
  (api.emit {:type :error :source :profiler :error text :text text}))

(fn parse-start [args]
  (let [parts (words args)
        opts {:period 25000 :mode :functions}]
    (var i 2)
    (var err nil)
    (while (and (<= i (length parts)) (not err))
      (let [part (. parts i)
            value (. parts (+ i 1))]
        (if (= part "--period")
            (let [n (tonumber value)]
              (if (and n (>= n 100) (= n (math.floor n)))
                  (do (set opts.period n) (set i (+ i 2)))
                  (set err "--period must be an integer of at least 100")))
            (= part "--mode")
            (if (or (= value "functions") (= value "lines"))
                (do (set opts.mode value) (set i (+ i 2)))
                (set err "--mode must be functions or lines"))
            (set err (.. "unknown profile option: " (tostring part))))))
    (values opts err)))

(fn status-text []
  (string.format
    "profile: %s; mode=%s period=%d samples=%d dropped=%d frames=%d stacks=%d cpu=%.3fs"
    (if state.enabled? "running" "stopped")
    (tostring state.mode)
    state.period
    state.sample-count
    state.dropped-samples
    (length state.frames)
    (length state.stacks)
    (state.elapsed-cpu)))

(fn perform [args]
  (let [parts (words args)
        sub (or (. parts 1) "status")]
    (if (= sub "start")
        (let [(opts err) (parse-start args)]
          (if err
              (values err true)
              (let [(ok? result) (pcall state.start! opts)]
                (if ok?
                    (.. "profile started: mode=" (tostring opts.mode)
                        " period=" (tostring opts.period)
                        " (Lua VM instruction samples, not wall time)")
                    (values (.. "profile start failed: " (tostring result)) true)))))
        (= sub "stop")
        (do (state.stop!) (status-text))
        (= sub "status")
        (status-text)
        (= sub "report")
        (.. (status-text) "\nlimitations: native/blocking time is not sampled; "
            "use TUI stall diagnostics alongside this capture")
        (= sub "reset")
        (do (state.reset!) "profile capture reset")
        (= sub "save")
        (let [output (. parts 2)
              was-running? state.enabled?]
          ;; Export iterates intern tables; stop first so the hook cannot mutate
          ;; them during serialization or profile the exporter itself.
          (when was-running? (state.stop!))
          (let [(ok? result) (pcall export.save! output)]
            (if ok?
                (.. "profile saved: " result.dir
                    (if was-running? " (capture stopped before export)" ""))
                (values (.. "profile export failed: " (tostring result)) true))))
        (or (= sub "help") (= sub "--help") (= sub "-h"))
        (usage)
        (values (.. "unknown profile command: " (tostring sub) "\n" (usage)) true))))

(fn handle [api args]
  (let [(text error?) (perform args)]
    (if error? (emit-error api text) (emit-info api text))))

(fn tool-result [text error?]
  {:content [(types.text-block text)] :is-error? error?})

;; @doc fen.extensions.profiler.commands.register
;; kind: function
;; signature: (register api) -> nil
;; summary: Register /profile controls and a cheap profiler-state introspection snapshot.
;; tags: profiler performance commands register
(fn M.register [api]
  (api.register :command
    {:name :profile
     :order 95
     :description "Capture Lua instruction samples; start|stop|status|report|save|reset; exports Speedscope and folded flame-graph stacks"
     :handler (fn [args _ctx] (handle api args))})
  (api.register :tool
    {:name :profile
     :label "Profile"
     :snippet "Control Lua instruction sampling"
     :description "Control fen's statistical profiler for self-investigation. Actions: start, status, report, stop, reset, or save. Start accepts period (at least 100) and mode (functions or lines); save optionally accepts an output directory. Samples measure Lua VM instructions, not wall-clock time."
     :parameters {:type :object
                  :properties {:action {:type :string
                                        :enum ["start" "status" "report" "stop" "reset" "save"]}
                               :period {:type :integer :minimum 100}
                               :mode {:type :string :enum ["functions" "lines"]}
                               :output-directory {:type :string}}
                  :required [:action]}
     :execute (fn [args _ctx]
                (let [action (or args.action "status")
                      command (if (= action "start")
                                  (.. action
                                      (if args.period (.. " --period " args.period) "")
                                      (if args.mode (.. " --mode " args.mode) ""))
                                  (= action "save")
                                  (.. action (if args.output-directory
                                                 (.. " " args.output-directory) ""))
                                  action)
                      (text error?) (perform command)]
                  (tool-result text error?)))})
  (api.register :introspect
    {:name :capture
     :description "Full profiler workflow for self-introspection: /profile start --period 50000 --mode functions; perform /reload, an agent turn, or tools; /profile status; /profile save [directory] stops and writes profile.speedscope.json, profile.folded, and profile.json. Speedscope/folded widths are Lua VM instruction samples, not milliseconds; correlate native or blocking gaps with tui-stall, make stall-check, or perf. The agent may inspect this capture snapshot with agent_state and control capture lifecycle with the profile tool."
     :snapshot (fn [_]
                 ;; Resolve reloadable export behavior at snapshot time.
                 ((. (require :fen.extensions.profiler.export) :snapshot)))}))

M
