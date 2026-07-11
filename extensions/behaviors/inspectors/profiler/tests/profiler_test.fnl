;; Statistical profiler command, sampler, and export tests.

(local h (require :fen.testing))
(local json (require :fen.util.json))
(local test-api (require :fen.core.extensions.test_api))
(local events (require :fen.core.extensions.events))
(local command-registry (require :fen.core.extensions.register.command))
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
                          :fen.extensions.profiler.export])]
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
          (assert.is_truthy (string.find folded " " 1 true)))))

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
