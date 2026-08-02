;; Statistical profiler command, sampler, and export tests.

(local h (require :fen.testing))
(local json (require :fen.util.json))
(local test-api (require :fen.core.extensions.test_api))
(local events (require :fen.core.extensions.events))
(local command-registry (require :fen.core.extensions.register.command))
(local tool-registry (require :fen.core.extensions.register.tool))
(local tools (require :fen.core.tools))
(local state (require :fen.extensions.profiler.state))
(local coroutines (require :fen.util.coroutines))

(fn read-all [filename]
  (let [f (assert (io.open filename :r))
        body (f:read :*a)]
    (f:close)
    body))

(fn burn-cpu []
  (var total 0)
  (for [i 1 5000]
    (set total (+ total (% i 17))))
  total)

(fn fresh-extension []
  (test-api.reset!)
  (state.reset!)
  (each [_ name (ipairs [:fen.extensions.profiler
                          :fen.extensions.profiler.commands
                          :fen.extensions.profiler.export
                          :fen.extensions.profiler.activity])]
    (tset package.loaded name nil))
  (let [seen []
        mod (require :fen.extensions.profiler)
        api (test-api.make-runtime-api :profiler)]
    (events.on :* (fn [ev] (table.insert seen ev)))
    (mod.register api)
    seen))

(fn last-event [seen type-key]
  (var found nil)
  (each [_ ev (ipairs seen)]
    (when (= ev.type type-key) (set found ev)))
  found)

(describe "fen.extensions.profiler"
  (fn []
    (var tmp nil)

    (before_each
      (fn []
        (set tmp (h.make-tmpdir))
        (fresh-extension)))

    (after_each
      (fn []
        (state.reset!)
        (test-api.reset!)
        (when tmp (h.rmtree tmp))))

    (it "captures bounded Lua instruction samples"
      (fn []
        (state.start! {:period 1000 :mode :functions
                       :max-frames 1000 :max-stacks 1000})
        (burn-cpu)
        (state.stop!)
        (assert.is_false state.enabled?)
        (assert.is_true (> state.sample-count 0))
        (assert.is_true (> (length state.frames) 0))
        (assert.is_true (> (length state.stacks) 0))
        (assert.are.equal 0 state.dropped-samples)
        (each [_ frame (ipairs state.frames)]
          (assert.is_nil
            (string.find frame.name "sample%-hook"))
          (assert.is_nil
            (string.find frame.name "capture%-stack")))))

    (it "propagates sampling into cooperative child coroutines"
      (fn []
        (state.start! {:period 1000 :mode :functions})
        (let [co (coroutines.create burn-cpu)
              before state.sample-count
              (ok? err) (coroutine.resume co)]
          (state.stop!)
          (assert.is_true ok? (tostring err))
          (assert.is_true (> state.sample-count before)))))

    (it "keeps the persistent hook and capture valid across behavior reload"
      (fn []
        (state.start! {:period 1000 :mode :functions})
        (let [hook state.hook
              before state.sample-count]
          ;; Reload only behavior modules, as the extension loader does;
          ;; state intentionally remains loaded and owns the hook identity.
          (each [_ name (ipairs [:fen.extensions.profiler
                                  :fen.extensions.profiler.commands
                                  :fen.extensions.profiler.export])]
            (tset package.loaded name nil))
          (require :fen.extensions.profiler)
          (burn-cpu)
          (state.stop!)
          (assert.are.equal hook state.hook)
          (assert.is_true (> state.sample-count before)))))

    (it "does not let stale inherited hooks sample a later capture"
      (fn []
        (state.start! {:period 100 :mode :functions})
        (let [co (coroutines.create burn-cpu)]
          (state.stop!)
          (state.start! {:period 1000000 :mode :functions})
          (let [(ok? err) (coroutine.resume co)]
            (state.stop!)
            (assert.is_true ok? (tostring err))
            (assert.are.equal 0 state.sample-count)
            (assert.is_nil (debug.gethook co))))))

    (it "does not propagate ordinary debugger hooks to child coroutines"
      (fn []
        (let [other-hook (fn [] nil)]
          (debug.sethook other-hook "" 1000000)
          (let [co (coroutines.create burn-cpu)]
            (debug.sethook)
            (assert.is_nil (debug.gethook co))))))

    (it "keeps capture memory bounded and reports dropped samples"
      (fn []
        (state.start! {:period 1000 :mode :lines
                       :max-frames 0 :max-stacks 1 :max-depth 16})
        (burn-cpu)
        (state.stop!)
        (assert.are.equal 0 (length state.frames))
        (assert.is_true (<= (length state.stacks) 1))
        (assert.is_true (> state.dropped-samples 0))))

    (it "exports separate coroutine profiles plus a merged view"
      (fn []
        (state.start! {:period 1000 :mode :functions})
        (burn-cpu)
        (let [co (coroutines.create burn-cpu)]
          (assert.is_true (coroutine.resume co)))
        (state.stop!)
        (let [export (require :fen.extensions.profiler.export)
              result (export.save! tmp)
              speedscope (json.decode (read-all result.speedscope))]
          (assert.is_true (>= (length speedscope.profiles) 3))
          (assert.is_truthy (string.find (. speedscope.profiles 1 :name)
                                         "merged" 1 true)))))

    (it "records bounded semantic spans and counters separately from samples"
      (fn []
        (local activity (require :fen.extensions.profiler.activity))
        (state.start! {:period 1000000 :max-spans 1 :max-counters 1})
        (let [span (activity.span-begin! :tui-tick {:reason :idle})]
          (assert.is_number span)
          (assert.is_true (activity.span-end! span)))
        (assert.is_nil (activity.span-begin! :overflow {}))
        (activity.counter-add! :tui-ticks)
        (activity.counter-add! :tui-ticks 2)
        (activity.counter-add! :overflow)
        (state.stop!)
        (let [export (require :fen.extensions.profiler.export)
              result (export.save! tmp)
              metadata (json.decode (read-all result.metadata))]
          (assert.are.equal 1 (length metadata.spans))
          (assert.are.equal "tui-tick" (. metadata.spans 1 :name))
          (assert.is_true (. metadata.spans 1 :finished?))
          (assert.are.equal 1 metadata.dropped-spans)
          (assert.are.equal 3 (. metadata.counters "tui-ticks"))
          (assert.are.equal 1 metadata.dropped-counters))))

    (it "rejects marks when no capture is running"
      (fn []
        (assert.is_false (state.mark! "idle"))
        (let [seen (fresh-extension)]
          (command-registry.dispatch "/profile mark idle" {})
          (let [ev (last-event seen :error)]
            (assert.is_truthy
              (string.find ev.error "requires a running capture" 1 true))))))

    (it "records blocking work as a bounded measured wall gap"
      (fn []
        (state.start! {:period 1000000 :wall-gap-ms 1 :max-wall-gaps 1})
        (state.record-wall-gap! {:source :test :phase :blocking-c
                                 :wall-ms 10 :cpu-ms 0 :opaque? true
                                 :budget-exceeded? false})
        (state.record-wall-gap! {:source :test :phase :overflow
                                 :wall-ms 10 :cpu-ms 0 :opaque? true
                                 :budget-exceeded? false})
        (state.stop!)
        (let [export (require :fen.extensions.profiler.export)
              result (export.save! tmp)
              metadata (json.decode (read-all result.metadata))]
          (assert.are.equal 1 (length (. metadata "wall-gaps")))
          (assert.are.equal "blocking-c" (. (. metadata "wall-gaps" 1) "phase"))
          (assert.are.equal 1 (. metadata "dropped-wall-gaps")))))

    (it "exports valid Speedscope, folded, and metadata artifacts"
      (fn []
        (state.start! {:period 1000 :mode :functions})
        (burn-cpu)
        (state.stop!)
        (let [export (require :fen.extensions.profiler.export)
              result (export.save! tmp)
              speedscope (json.decode (read-all result.speedscope))
              metadata (json.decode (read-all result.metadata))
              folded (read-all result.folded)]
          (assert.are.equal
            "https://www.speedscope.app/file-format-schema.json"
            (. speedscope "$schema"))
          (assert.are.equal "sampled" (. speedscope.profiles 1 :type))
          (assert.are.equal "none" (. speedscope.profiles 1 :unit))
          (assert.are.equal "lua-vm-instructions" (. metadata "sample-kind"))
          (assert.are.equal state.sample-count (. metadata "sample-count"))
          (assert.are.equal "measured monotonic milliseconds"
                            (. (. metadata "time-units") "wall-gaps"))
          (assert.is_truthy (string.find (. metadata "interpretation")
                                         "not elapsed milliseconds" 1 true))
          (assert.is_truthy (string.find (. metadata "workflow" 1)
                                         "/profile start" 1 true))
          (assert.are.equal "/profile save [output-directory]"
                            (. metadata "commands" "save"))
          (assert.is_truthy (string.find folded " " 1 true)))))

    (it "profile tool controls capture for agent self-investigation"
      (fn []
        (let [registered (tool-registry.merged [])
              started (tools.execute-call registered
                        {:name :profile :arguments {:action "start" :period 1000}}
                        {})]
          (assert.is_true state.enabled?)
          (assert.is_truthy (string.find (. started.result.content 1 :text)
                                         "profile started" 1 true))
          (let [stopped (tools.execute-call registered
                          {:name :profile :arguments {:action "stop"}} {})]
            (assert.is_false state.enabled?)
            (assert.is_truthy (string.find (. stopped.result.content 1 :text)
                                           "profile: stopped" 1 true))))))

    (it "profile tool preserves spaces in an export directory"
      (fn []
        (let [registered (tool-registry.merged [])
              output (.. tmp "/My Profiles")
              saved (tools.execute-call
                      registered
                      {:name :profile
                       :arguments {:action "save" :output-directory output}}
                      {})]
          (assert.is_false saved.result.is-error?)
          (assert.is_truthy (read-all (.. output "/profile.speedscope.json"))))))

    (it "/profile controls capture and saves after stopping"
      (fn []
        (let [seen (fresh-extension)]
          (command-registry.dispatch "/profile start --period 1000 --mode functions" {})
          (burn-cpu)
          (assert.is_true state.enabled?)
          (command-registry.dispatch (.. "/profile save " tmp) {})
          (assert.is_false state.enabled?)
          (assert.is_truthy (last-event seen :info))
          (assert.is_truthy (read-all (.. tmp "/profile.speedscope.json"))))))

    (it "does not overwrite another active debug hook"
      (fn []
        (let [other-hook (fn [] nil)]
          (debug.sethook other-hook "" 1000)
          (let [(ok? err) (pcall state.start! {:period 1000})
                (hook _mask _count) (debug.gethook)]
            (debug.sethook)
            (assert.is_false ok?)
            (assert.is_truthy
              (string.find (tostring err) "another debug hook" 1 true))
            (assert.are.equal other-hook hook)))))

    (it "rejects invalid sampling options"
      (fn []
        (let [seen (fresh-extension)]
          (command-registry.dispatch "/profile start --period 2" {})
          (assert.is_false state.enabled?)
          (let [ev (last-event seen :error)]
            (assert.is_not_nil ev)
            (assert.is_truthy
              (string.find ev.error "at least 100" 1 true))))))))
