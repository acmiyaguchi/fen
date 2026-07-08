;; Reusable deterministic TUI story fixtures.
;;
;; These are dev/test helpers: each story resets the persistent TUI state table
;; and seeds one representative UI state without driving a live session. The
;; registry is intentionally plain data plus small setup functions so future
;; golden tests and interactive runners can reuse the same fixtures.

(local state (require :fen.extensions.tui.state))

(local M {})

(fn status-defaults []
  {:model nil
   :provider nil
   :thinking-status nil
   :cum-input 0
   :cum-output 0
   :cum-cache-read 0
   :cum-cache-write 0
   :last-input 0
   :approx-context 0
   :steering-queued 0
   :follow-up-queued 0
   :start-ms 0
   :running-label nil
   :running-tools nil
   :retrying? false
   :retry-attempt 0
   :retry-max-attempts 0
   :retry-delay-ms 0
   :retry-reason nil
   :thinking? false
   :cancelling? false
   :turn-start 0
   :spin-frame 0})

;; @doc fen.extensions.tui.stories.reset!
;; kind: function
;; signature: (reset! ?opts) -> table
;; summary: Reset persistent TUI state to a deterministic baseline for story setup and tests.
;; tags: tui stories testing state
(fn M.reset! [?opts]
  "Reset persistent TUI state fields used by story fixtures. This avoids the
   real presenter lifecycle and does not initialize termbox."
  (let [opts (or ?opts {})]
    (set state.tb-cols (or opts.cols 80))
    (set state.tb-rows (or opts.rows 24))
    (set state.tb-initialized? false)
    (set state.tb-init-failed? false)
    (set state.dirty? false)
    (set state.force-redraw? false)
    (set state.spinner-ticks 0)
    (set state.spinner-interval-ticks 8)
    (set state.animations? true)

    (set state.transcript [])
    (set state.streaming-assistant-rows {})
    (set state.transcript-layout-cache nil)
    (set state.scroll-offset 0)
    (set state.new-content-below? false)
    (set state.last-user-jump-index nil)

    (set state.input-buf "")
    (set state.input-cursor 0)
    (set state.paste-active? false)
    (set state.paste-buffer "")
    (set state.paste-counter 0)
    (set state.pastes {})

    (set state.selection nil)
    (set state.selection-paint nil)
    (set state.copy-status nil)

    (set state.history [])
    (set state.history-pos 0)
    (set state.history-draft "")

    (set state.expand-tool-results? false)
    (set state.markdown? false)
    (set state.hide-thinking-block? false)
    (set state.pending-quit? false)
    (set state.alt-pending? false)
    (set state.cancel-pressed? false)
    (set state.on-tick nil)
    (set state.presenter-ctx nil)

    (set state.completion {:active? false
                           :cursor 1
                           :items []
                           :kind :command
                           :buf-snapshot nil
                           :cursor-snapshot nil})
    (set state.error-panel-visible? false)
    (set state.errors [])
    (set state.errors-visible? false)
    (set state.status-info (status-defaults))
    state))

(fn transcript-rows [n]
  (let [rows []]
    (for [i 1 n]
      (table.insert rows
                    {:type (if (= (% i 3) 1) :user :assistant-text)
                     :text (.. (if (= (% i 3) 1) "prompt " "response ")
                               (tostring i))}))
    rows))

(fn seed-idle [_state _opts]
  nil)

(fn seed-busy-tool [s _opts]
  (set s.status-info.running-label "$ make test")
  (set s.status-info.turn-start 0)
  (set s.status-info.spin-frame 0)
  (set s.transcript [{:type :user :text "run the focused tests"}
                     {:type :assistant-text
                      :text "I'll run the focused test command now."}]))

(fn seed-completion [s _opts]
  (set s.input-buf "/re")
  (set s.input-cursor (length s.input-buf))
  (set s.completion {:active? true
                     :cursor 1
                     :kind :command
                     :buf-snapshot s.input-buf
                     :cursor-snapshot s.input-cursor
                     :items [{:label "reload" :value "reload"
                              :description "Reload extensions from source"}
                             {:label "redraw" :value "redraw"
                              :description "Force a full TUI redraw"}]}))

(fn seed-scrolled [s _opts]
  (set s.transcript (transcript-rows 14))
  (set s.scroll-offset 6)
  (set s.new-content-below? true)
  (set s.last-user-jump-index 10))

(fn seed-errors [s _opts]
  (set s.transcript [{:type :user :text "load the extension"}
                     {:type :error
                      :error "example failure while loading extension"
                      :traceback "stack traceback:\n  stories/example.fnl:12: boom"}
                     {:type :extension-error
                      :owner :demo
                      :event :turn-complete
                      :error "handler failed"
                      :traceback "stack traceback:\n  demo/init.fnl:8: bad argument"}])
  (set s.error-panel-visible? true))

(fn seed-narrow-status [s _opts]
  (set s.status-info.provider "anthropic")
  (set s.status-info.model "claude-sonnet")
  (set s.status-info.approx-context 12345)
  (set s.status-info.steering-queued 2)
  (set s.status-info.follow-up-queued 1)
  (set s.scroll-offset 4)
  (set s.new-content-below? true)
  (set s.transcript [{:type :user :text "summarize the narrow layout"}
                     {:type :assistant-text
                      :text "This state stresses status item clipping."}]))

(local STORIES
  [{:name :idle-empty
    :description "Idle TUI with an empty input and empty transcript"
    :tags [:idle]
    :cols 80
    :rows 24
    :setup seed-idle}
   {:name :busy-tool
    :description "Busy panel while one tool command is running"
    :tags [:busy :tool]
    :cols 80
    :rows 24
    :setup seed-busy-tool}
   {:name :slash-completion
    :description "Slash-command completion menu open above the input"
    :tags [:completion :input]
    :cols 80
    :rows 24
    :setup seed-completion}
   {:name :scrolled-transcript
    :description "Transcript scrolled away from the live bottom with new content below"
    :tags [:scroll :transcript]
    :cols 80
    :rows 12
    :setup seed-scrolled}
   {:name :errors-panel
    :description "Errors panel open with recent error and extension-error rows"
    :tags [:errors :panel]
    :cols 80
    :rows 24
    :setup seed-errors}
   {:name :narrow-status
    :description "Small terminal stressing compact status bar layout"
    :tags [:status :narrow]
    :cols 32
    :rows 10
    :setup seed-narrow-status}])

(fn story-metadata [story]
  {:name story.name
   :description story.description
   :tags story.tags
   :cols story.cols
   :rows story.rows})

;; @doc fen.extensions.tui.stories.list
;; kind: function
;; signature: (list) -> [StoryMetadata]
;; summary: List discoverable TUI story names, descriptions, tags, and default dimensions.
;; tags: tui stories registry testing
(fn M.list []
  (icollect [_ story (ipairs STORIES)]
    (story-metadata story)))

;; @doc fen.extensions.tui.stories.find
;; kind: function
;; signature: (find name) -> Story|nil
;; summary: Return a TUI story fixture by keyword/string name.
;; tags: tui stories registry testing
(fn M.find [name]
  (var found nil)
  (each [_ story (ipairs STORIES)]
    (when (= (tostring story.name) (tostring name))
      (set found story)))
  found)

;; @doc fen.extensions.tui.stories.setup!
;; kind: function
;; signature: (setup! name ?opts) -> table
;; summary: Reset persistent TUI state and seed the named story fixture in-process.
;; tags: tui stories registry testing state
(fn M.setup! [name ?opts]
  "Reset and seed a named story. Optional opts may override :cols/:rows."
  (let [story (M.find name)
        opts (or ?opts {})]
    (assert story (.. "unknown TUI story: " (tostring name)))
    (M.reset! {:cols (or opts.cols story.cols 80)
               :rows (or opts.rows story.rows 24)})
    (story.setup state opts)
    state))

M
