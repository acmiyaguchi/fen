;; /profile controls for the opt-in statistical profiler.

(local state (require :fen.extensions.profiler.state))
(local export (require :fen.extensions.profiler.export))

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

(fn handle [api args]
  (let [parts (words args)
        sub (or (. parts 1) "status")]
    (if (= sub "start")
        (let [(opts err) (parse-start args)]
          (if err
              (emit-error api err)
              (let [(ok? result) (pcall state.start! opts)]
                (if ok?
                    (emit-info api
                      (.. "profile started: mode=" (tostring opts.mode)
                          " period=" (tostring opts.period)
                          " (Lua VM instruction samples, not wall time)"))
                    (emit-error api (.. "profile start failed: " (tostring result)))))))
        (= sub "stop")
        (do (state.stop!) (emit-info api (status-text)))
        (= sub "status")
        (emit-info api (status-text))
        (= sub "report")
        (emit-info api (.. (status-text) "\n"
                           "limitations: native/blocking time is not sampled; "
                           "use TUI stall diagnostics alongside this capture"))
        (= sub "reset")
        (do (state.reset!) (emit-info api "profile capture reset"))
        (= sub "save")
        (let [output (. parts 2)
              was-running? state.enabled?]
          ;; Export iterates intern tables; stop first so the hook cannot mutate
          ;; them during serialization or profile the exporter itself.
          (when was-running? (state.stop!))
          (let [(ok? result) (pcall export.save! output)]
            (if ok?
                (emit-info api
                  (.. "profile saved: " result.dir
                      (if was-running? " (capture stopped before export)" "")))
                (emit-error api (.. "profile export failed: " (tostring result))))))
        (or (= sub "help") (= sub "--help") (= sub "-h"))
        (emit-info api (usage))
        (emit-error api (.. "unknown profile command: " (tostring sub) "\n" (usage))))))

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
  (api.register :introspect
    {:name :capture
     :description "Full profiler workflow for self-introspection: /profile start --period 50000 --mode functions; perform /reload, an agent turn, or tools; /profile status; /profile save [directory] stops and writes profile.speedscope.json, profile.folded, and profile.json. Speedscope/folded widths are Lua VM instruction samples, not milliseconds; correlate native or blocking gaps with tui-stall, make stall-check, or perf. The agent may inspect this capture snapshot with agent_state, but only the human /profile command controls capture lifecycle."
     :snapshot (fn [_]
                 ;; Resolve reloadable export behavior at snapshot time.
                 ((. (require :fen.extensions.profiler.export) :snapshot)))}))

M
