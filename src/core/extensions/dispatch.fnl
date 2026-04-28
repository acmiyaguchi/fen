;; Small bucket-of-contributions modules collected in one place.
;;
;; Three concerns, all the same shape (register a contribution against
;; `core.extensions.state`, read it back from a sibling module):
;;
;;   - events:   on/emit a synchronous in-process event bus.
;;   - commands: register and dispatch slash commands.
;;   - prompt:   register and render system-prompt fragments.

(local state (require :core.extensions.state))
(local util (require :core.extensions.util))
(local log (require :util.log))

(local M {})

;; ============================================================
;; Events
;; ============================================================

(fn append-handler [event-name entry]
  (let [bucket (or (. state.handlers event-name) [])]
    (table.insert bucket entry)
    (tset state.handlers event-name bucket)))

(fn remove-handler [event-name entry]
  (let [bucket (. state.handlers event-name)]
    (when bucket
      (util.remove-where bucket (fn [e _] (= e entry))))))

(fn report-handler-error [entry ev err]
  "Surface extension event-handler failures without recursive diagnostics."
  (let [event-type (?. ev :type)
        owner (or entry.owner :anonymous)
        msg (.. "extension handler failed"
                " owner=" (tostring owner)
                " event=" (tostring event-type)
                ": " (tostring err))]
    (log.warn msg)
    (when (not= event-type :extension-error)
      (M.emit {:type :extension-error
               :owner owner
               :event event-type
               :error (tostring err)}))))

(fn dispatch-bucket [bucket ev]
  (when bucket
    (each [_ entry (ipairs bucket)]
      (let [(ok? err) (pcall entry.fn ev)]
        (when (not ok?)
          (report-handler-error entry ev err))))))

(fn M.emit [ev]
  "Dispatch ev to handlers[ev.type] and the `:*` wildcard bucket."
  (when (and ev ev.type)
    (dispatch-bucket (. state.handlers ev.type) ev))
  (dispatch-bucket (. state.handlers :*) ev)
  nil)

(fn M.on [event-name handler ?owner]
  "Subscribe handler to event-name. Returns unsubscribe function."
  (let [entry {:fn handler :owner ?owner}]
    (append-handler event-name entry)
    (fn [] (remove-handler event-name entry))))

;; ============================================================
;; Commands
;; ============================================================

(fn parse-slash [line]
  "Split `/foo bar baz` into (\"foo\", \"bar baz\")."
  (let [stripped (string.match line "^/(.*)$")]
    (if (or (not stripped) (= stripped ""))
        (values nil "")
        (let [space-idx (string.find stripped "%s")]
          (if space-idx
              (values (string.sub stripped 1 (- space-idx 1))
                      (string.sub stripped (+ space-idx 1)))
              (values stripped ""))))))

(fn M.dispatch-command [line caller-state]
  "Look up and pcall-isolate a registered slash command."
  (let [(name args) (parse-slash line)]
    (if (not name)
        (M.emit {:type :error :error "empty command (try /help)"})
        (let [rec (. state.commands-extra name)]
          (if (not rec)
              (M.emit {:type :error
                       :error (.. "unknown command: /" name " (try /help)")})
              (and rec.idle-only? caller-state.busy?)
              (M.emit {:type :error
                       :error (.. "/" name
                                  " is disabled while the agent is running")})
              (let [(ok? err) (pcall rec.handler args caller-state)]
                (when (not ok?)
                  (M.emit {:type :error
                           :error (.. "/" name ": " (tostring err))}))))))))

;; ============================================================
;; Prompt fragments
;; ============================================================

(set M.PROMPT-SLOTS [:before-body :before-context :end])

(fn M.slot-valid? [slot]
  (var found false)
  (each [_ s (ipairs M.PROMPT-SLOTS)]
    (when (= s slot) (set found true)))
  found)

(fn handle-result [kind name owner unregister]
  {: kind : name : owner : unregister})

(fn M.contribute [text-or-fn ?opts owner]
  (let [opts (or ?opts {})
        slot (or opts.slot :end)]
    (when (not (M.slot-valid? slot))
      (error (.. "prompt: unknown slot " (tostring slot))))
    (let [bucket (. state.prompt-fragments slot)
          entry {:text-or-fn text-or-fn :owner owner}]
      (table.insert bucket entry)
      (handle-result :system-prompt-fragment slot owner
        (fn []
          (util.remove-where bucket (fn [e _] (= e entry))))))))

(fn render-fragment [entry]
  (let [val entry.text-or-fn]
    (if (= (type val) :function)
        (let [(ok? result) (pcall val)]
          (if ok?
              result
              (.. "<!-- extension "
                  (tostring entry.owner)
                  " failed: "
                  (tostring result)
                  " -->")))
        val)))

(fn M.fragments-for [slot]
  "Render registered fragments for slot, or nil when none render."
  (let [bucket (. state.prompt-fragments slot)]
    (if (or (not bucket) (= (length bucket) 0))
        nil
        (let [parts []]
          (each [_ entry (ipairs bucket)]
            (let [rendered (render-fragment entry)]
              (when (and rendered (not= rendered ""))
                (table.insert parts (tostring rendered)))))
          (if (= (length parts) 0)
              nil
              (table.concat parts "\n\n"))))))

M
