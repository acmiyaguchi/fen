;; Runtime memory diagnostics extension.

(local extensions (require :core.extensions))
(local state (require :extensions.mem.state))

(local OWNER :mem)
(local M {})

(fn round1 [n]
  (/ (math.floor (+ (* (or n 0) 10) 0.5)) 10))

(fn fmt-kb [n]
  (.. (tostring (round1 n)) " KB"))

(fn proc-status []
  "Return Linux process memory fields from /proc/self/status when available."
  (let [(f _err) (io.open "/proc/self/status" :r)
        out {}]
    (when f
      (each [line (f:lines)]
        (let [(k v) (string.match line "^(Vm%w+):%s+(%d+)%s+kB")]
          (when k
            (tset out k (tonumber v)))))
      (f:close))
    out))

(fn count-list [xs]
  (length (or xs [])))

(fn count-event-handlers [handlers]
  (var buckets 0)
  (var handlers-count 0)
  (each [_ entries (pairs (or handlers {}))]
    (set buckets (+ buckets 1))
    (set handlers-count (+ handlers-count (count-list entries))))
  (values buckets handlers-count))

(fn push-sample! [kb]
  (table.insert state.samples kb)
  (while (> (length state.samples) state.max-samples)
    (table.remove state.samples 1))
  (when (> kb (or state.peak-kb 0))
    (set state.peak-kb kb)))

(fn bar [value max-value width]
  (let [max-value (if (> (or max-value 0) 0) max-value 1)
        filled (math.floor (+ (* (/ value max-value) width) 0.5))
        parts []]
    (for [i 1 width]
      (table.insert parts (if (<= i filled) "#" ".")))
    (table.concat parts "")))

(fn history-lines []
  (let [lines []]
    (when (> (length state.samples) 1)
      (table.insert lines "History")
      (each [i kb (ipairs state.samples)]
        (table.insert lines
          (.. "  " (string.format "%02d" i)
              " [" (bar kb state.peak-kb 20) "] "
              (fmt-kb kb)))))
    lines))

(fn registry-lines []
  (let [tools (extensions.list :tools)
        commands (extensions.list :commands)
        fragments (extensions.list :prompt-fragments)
        exts (extensions.list :extensions)
        handlers (extensions.list :event-handlers)
        (event-buckets event-handlers) (count-event-handlers handlers)]
    ["Registries"
     (.. "  extensions: " (count-list exts))
     (.. "  tools: " (count-list tools))
     (.. "  commands: " (count-list commands))
     (.. "  prompt fragments: " (count-list fragments))
     (.. "  event handlers: " event-handlers " in " event-buckets " buckets")]))

(fn app-lines [run-state]
  (let [agent (?. run-state :agent)
        session (?. run-state :session)
        lines ["App"]]
    (table.insert lines (.. "  messages: " (count-list (?. agent :messages))))
    (when session
      (when session.id
        (table.insert lines (.. "  session id: " (tostring session.id))))
      (when session.path
        (table.insert lines (.. "  session path: " (tostring session.path)))))
    lines))

(fn append-proc-lines! [lines proc]
  (when proc.VmRSS
    (table.insert lines (.. "  process RSS:        " (fmt-kb proc.VmRSS))))
  (when proc.VmHWM
    (table.insert lines (.. "  process peak RSS:   " (fmt-kb proc.VmHWM))))
  (when proc.VmSize
    (table.insert lines (.. "  process vm size:    " (fmt-kb proc.VmSize)))))

(fn M.report [run-state gc?]
  (let [before (collectgarbage :count)]
    (when gc?
      (collectgarbage :collect))
    (let [after (collectgarbage :count)
          collected (- before after)
          proc (proc-status)
          lines ["Memory"]]
      (if gc?
          (do
            (table.insert lines (.. "  lua heap before GC: " (fmt-kb before)))
            (table.insert lines (.. "  lua heap after GC:  " (fmt-kb after)))
            (table.insert lines (.. "  collected:          " (fmt-kb collected))))
          (table.insert lines (.. "  lua heap:           " (fmt-kb after))))
      (push-sample! after)
      (table.insert lines (.. "  peak observed heap: " (fmt-kb state.peak-kb)))
      (append-proc-lines! lines proc)
      (table.insert lines "")
      (each [_ line (ipairs (app-lines run-state))]
        (table.insert lines line))
      (table.insert lines "")
      (each [_ line (ipairs (registry-lines))]
        (table.insert lines line))
      (let [history (history-lines)]
        (when (> (length history) 0)
          (table.insert lines "")
          (each [_ line (ipairs history)]
            (table.insert lines line))))
      (table.concat lines "\n"))))

(fn register! []
  (extensions.unregister-by-owner OWNER)
  (let [api (extensions.make-api OWNER)]
    (api.register :command
      {:name :mem
       :order 80
       :description "Show Lua heap and extension registry memory diagnostics"
       :handler (fn [args run-state]
                  (let [gc? (= (string.lower (or (string.match (or args "") "^%s*(%S+)") "")) "gc")]
                    (extensions.emit {:type :assistant-text
                                      :text (M.report run-state gc?)})))}))
  true)

(set M.register! register!)
(set M._state state)

(register!)

M
