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

(fn speedscope-data []
  (let [frames []
        samples []
        weights []]
    (each [_ frame (ipairs state.frames)]
      (table.insert frames {:name frame.name
                            :file frame.file
                            :line frame.line}))
    (each [_ id (ipairs (sorted-stack-ids))]
      (let [sample []]
        (each [_ frame-id (ipairs (. state.stacks id))]
          ;; Speedscope frame indexes are zero-based.
          (table.insert sample (- frame-id 1)))
        (table.insert samples sample)
        (table.insert weights (. state.counts id))))
    {:$schema "https://www.speedscope.app/file-format-schema.json"
     :shared {:frames frames}
     :profiles [{:type :sampled
                 :name "fen Lua VM instruction samples"
                 :unit :none
                 :startValue 0
                 :endValue state.sample-count
                 :samples samples
                 :weights weights}]
     :activeProfileIndex 0
     :exporter "fen statistical profiler"}))

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
            :max-threads state.max-threads}
   :threads state.threads
   :limitations ["Samples are weighted by Lua VM instructions, not elapsed time."
                 "Blocking native/C work produces no count-hook samples."
                 "Only threads explicitly hooked by the profiler are sampled."]})

(fn default-output-dir []
  (let [base (.. (path.state-dir :fen) "/profiles/"
                 (os.date "!%Y%m%dT%H%M%SZ"))]
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
