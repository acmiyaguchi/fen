;; Export statistical captures to standard flame-graph formats.

(local json (require :fen.util.json))
(local path (require :fen.util.path))
(local state (require :fen.extensions.profiler.state))

(local M {})

(fn write-file! [filename content]
  (let [f (assert (io.open filename :w))]
    (f:write content)
    (f:write "\n")
    (f:close)))

(fn sorted-stack-ids []
  (let [ids []]
    (each [id count (pairs state.counts)]
      (when (> count 0) (table.insert ids id)))
    (table.sort ids)
    ids))

(fn sampled-profile [name ids]
  (let [samples []
        weights []]
    (each [_ id (ipairs ids)]
      (let [sample []]
        (each [_ frame-id (ipairs (. state.stacks id))]
          ;; Speedscope frame indexes are zero-based.
          (table.insert sample (- frame-id 1)))
        (table.insert samples sample)
        (table.insert weights (. state.counts id))))
    {:type :sampled :name name :unit :none :startValue 0
     :endValue (length samples) :samples samples :weights weights}))

(fn speedscope-data []
  (let [frames []
        all-ids (sorted-stack-ids)
        by-thread {}]
    (each [_ frame (ipairs state.frames)]
      (table.insert frames {:name frame.name :file frame.file :line frame.line}))
    (each [_ id (ipairs all-ids)]
      (let [thread-id (. state.stack-threads id)]
        (when (not (. by-thread thread-id)) (tset by-thread thread-id []))
        (table.insert (. by-thread thread-id) id)))
    (let [profiles [(sampled-profile "fen Lua VM instruction samples (merged)" all-ids)]
          thread-ids []]
      (each [thread-id _ (pairs by-thread)] (table.insert thread-ids thread-id))
      (table.sort thread-ids)
      (each [_ thread-id (ipairs thread-ids)]
        (table.insert profiles
          (sampled-profile (.. "fen Lua VM instruction samples (" thread-id ")")
                           (. by-thread thread-id))))
      {:$schema "https://www.speedscope.app/file-format-schema.json"
       :shared {:frames frames}
       :profiles profiles
       :activeProfileIndex 0
       :exporter "fen statistical profiler"})))

(fn folded-name [s]
  (let [(cleaned _count) (string.gsub (tostring s) "[;\r\n]" " ")]
    cleaned))

(fn folded-data []
  (let [lines []]
    (each [_ id (ipairs (sorted-stack-ids))]
      (let [names []]
        (each [_ frame-id (ipairs (. state.stacks id))]
          (table.insert names (folded-name (. state.frames frame-id :name))))
        (table.insert lines
          (.. (table.concat names ";") " " (tostring (. state.counts id))))))
    (table.concat lines "\n")))

(fn metadata []
  {:format-version 1
   :sample-kind "lua-vm-instructions"
   :sample-unit "count-hook samples; not wall-clock time"
   :period state.period
   :mode state.mode
   :enabled? state.enabled?
   :started-wall state.started-wall
   :stopped-wall state.stopped-wall
   :elapsed-cpu-seconds (state.elapsed-cpu)
   :sample-count state.sample-count
   :dropped-samples state.dropped-samples
   :distinct-frames (length state.frames)
   :distinct-stacks (length state.stacks)
   :limits {:max-frames state.max-frames
            :max-stacks state.max-stacks
            :max-depth state.max-depth
            :max-threads state.max-threads
            :max-wall-gaps state.max-wall-gaps
            :max-marks state.max-marks}
   :wall-gap-threshold-ms state.wall-gap-ms
   :wall-gaps state.wall-gaps
   :dropped-wall-gaps state.dropped-wall-gaps
   :marks state.marks
   :time-units {:lua-samples "Lua VM instruction-count samples (not milliseconds)"
                :wall-gaps "measured monotonic milliseconds"
                :cpu "measured process CPU seconds"
                :native-samples "not captured; correlate with external perf"}
   :threads state.threads
   :workflow ["Start a capture: /profile start --period 50000 --mode functions"
              "Perform the operation to measure, for example /reload or an agent turn."
              "Inspect progress if needed: /profile status"
              "Save and stop: /profile save [output-directory]"
              "Open profile.speedscope.json in Speedscope, or use profile.folded with FlameGraph tooling."
              "Correlate missing native/blocking time with tui-stall logs, make stall-check, or perf."]
   :commands {:start "/profile start [--period N] [--mode functions|lines]"
              :status "/profile status"
              :stop "/profile stop"
              :report "/profile report"
              :save "/profile save [output-directory]"
              :reset "/profile reset"
              :help "/profile help"}
   :artifacts {:speedscope "profile.speedscope.json — interactive sampled flame graph"
               :folded "profile.folded — root-to-leaf folded stacks and sample weights"
               :metadata "profile.json — configuration, counts, limits, workflow, and interpretation"}
   :interpretation "Frame width represents Lua VM instruction-count samples, not elapsed milliseconds. Wall gaps are separately measured monotonic intervals around TUI input/tick work and may include opaque native/C time; CPU duration is process CPU time. Larger --period values reduce overhead and detail; use function mode by default and line mode for short focused captures."
   :agent-access "The model may inspect this snapshot through agent_state and start, stop, reset, or save captures with the profile tool."
   :limitations ["Samples are weighted by Lua VM instructions, not elapsed time."
                 "Blocking native/C work produces no count-hook samples; qualifying TUI input/tick intervals are recorded separately as measured wall gaps."
                 "Only the current thread and fen cooperative child coroutines created during a capture are sampled."
                 "Direct coroutine.create calls retain Lua's thread-local hook behavior and are not automatically sampled."]})

(fn default-output-dir []
  (let [configured (os.getenv :FEN_PROFILE_OUTPUT)
        base (or (and configured (not= configured "") configured)
                 (.. (path.state-dir :fen) "/profiles/"
                     (os.date "!%Y%m%dT%H%M%SZ")))]
    (if (not (path.dir-exists? base))
        base
        (let []
          (var candidate nil)
          (var i 1)
          (while (and (not candidate) (< i 10000))
            (let [next (.. base "-" (tostring i))]
              (when (not (path.dir-exists? next))
                (set candidate next)))
            (set i (+ i 1)))
          (or candidate (error "could not allocate a unique profile output directory"))))))

;; @doc fen.extensions.profiler.export.save!
;; kind: function
;; signature: (save! output-dir?) -> {dir, speedscope, folded, metadata}
;; summary: Export the current bounded statistical capture as Speedscope JSON, folded stacks, and explicit metadata.
;; tags: profiler performance export
(fn M.save! [?output-dir]
  (let [dir (or (and ?output-dir (not= ?output-dir "") ?output-dir)
                (default-output-dir))
        speedscope (.. dir "/profile.speedscope.json")
        folded (.. dir "/profile.folded")
        metadata-path (.. dir "/profile.json")]
    (path.ensure-dir! dir)
    (write-file! speedscope (json.encode (speedscope-data)))
    (write-file! folded (folded-data))
    (write-file! metadata-path (json.encode (metadata)))
    {:dir dir :speedscope speedscope :folded folded :metadata metadata-path}))

(fn M.snapshot [] (metadata))

M
