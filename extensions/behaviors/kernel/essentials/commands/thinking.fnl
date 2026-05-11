;; /thinking command: inspect and change provider-neutral thinking effort.
;;
;; The TUI owns thinking-block visibility, but this command owns the runtime
;; provider knob. `/thinking blocks on|off` emits a presenter event so the
;; visibility spelling can live under the same user-facing command without
;; making kernel essentials depend on TUI internals.

(local thinking (require :fen.core.thinking))

(local M {})

(fn trim [s]
  (or (string.match (or s "") "^%s*(.-)%s*$") ""))

(fn first-rest [args]
  (let [s (trim args)
        first (string.match s "^(%S+)")]
    (if first
        (values first (trim (string.sub s (+ (length first) 1))))
        (values nil ""))))

(fn current-level [state]
  (let [opts (or (?. state :opts) {})]
    (or opts.thinking
        (and opts.reasoning-effort
             (.. "effort:" (tostring opts.reasoning-effort)))
        (and opts.thinking-budget
             (.. "budget:" (tostring opts.thinking-budget)))
        :off)))

(fn status-text [state]
  (let [level (current-level state)
        materialized (or (?. state :agent :thinking-status) "off")]
    (.. "thinking: " (tostring level)
        " (" (tostring materialized) ")\n"
        "levels: " (thinking.level-list) "\n"
        "visibility: /thinking blocks on|off")))

(fn refresh-status! [api state]
  (api.emit
    {:type :set-status-info
     :info {:provider state.opts.provider
            :model state.agent.model
            :thinking-status state.agent.thinking-status}}))

(fn rebuild-agent! [state]
  (let [saved state.agent.messages
        new-agent (state.make-agent-from-opts
                    state.opts state.on-event state.agent-extra)]
    (set new-agent.messages saved)
    (set state.agent new-agent)))

(fn persist-level! [api level]
  (let [(ok? err) (pcall api.settings.set-thinking-default! level)]
    (when (not ok?)
      (api.emit {:type :error
                 :error (.. "failed to persist default thinking: "
                            (tostring err))}))))

(fn set-level! [api state raw-level]
  (let [level (thinking.normalize-level raw-level)]
    (if (not level)
        (api.emit {:type :error
                   :error (.. "invalid thinking level: " (tostring raw-level)
                              " (expected " (thinking.level-list) ")")})
        (do
          (set state.opts.thinking level)
          ;; Exact provider-specific overrides win over :thinking during
          ;; materialization. Clear them so the runtime command does what it
          ;; says even if the process started with an exact CLI override.
          (set state.opts.thinking-budget nil)
          (set state.opts.reasoning-effort nil)
          (rebuild-agent! state)
          (persist-level! api level)
          (when state.update-queue-status (state.update-queue-status))
          (refresh-status! api state)
          (api.emit {:type :info
                     :text (.. "thinking: " (tostring level)
                               " (" (tostring (or state.agent.thinking-status "off")) ")")})))))

(fn set-blocks! [api arg]
  (if (or (= arg nil) (= arg ""))
      (api.emit {:type :error :error "usage: /thinking blocks on|off"})
      (let [visible? (if (= arg :on) true
                         (= arg "on") true
                         (= arg :off) false
                         (= arg "off") false
                         nil)]
        (if (= visible? nil)
            (api.emit {:type :error :error "usage: /thinking blocks on|off"})
            (do
              (api.emit {:type :set-thinking-blocks :visible? visible?})
              (api.emit {:type :info
                         :text (.. "thinking blocks: "
                                   (if visible? "visible" "hidden"))}))))))

(fn handle-thinking [api args state]
  (let [(cmd rest) (first-rest args)]
    (if (or (= cmd nil) (= cmd "") (= cmd :status) (= cmd "status"))
        (api.emit {:type :assistant-text :text (status-text state)})
        (or (= cmd :blocks) (= cmd "blocks"))
        (let [(arg _) (first-rest rest)]
          (set-blocks! api arg))
        (not state)
        (api.emit {:type :error :error "/thinking requires an active run"})
        (not (and state.opts state.agent state.make-agent-from-opts))
        (api.emit {:type :error :error "/thinking cannot rebuild the active agent"})
        (set-level! api state cmd))))

;; @doc fen.extensions.essentials.commands.thinking.register
;; kind: function
;; signature: (register api) -> nil
;; summary: Register the /thinking command for inspecting and setting provider-neutral thinking effort.
;; tags: commands thinking register
(fn M.register [api]
  (api.register :command
    {:name :thinking
     :order 13
     :description "Show/set thinking effort; /thinking blocks on|off toggles display"
     :idle-only? true
     :handler (fn [args state] (handle-thinking api args state))}))

M
