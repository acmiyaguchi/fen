;; Inline slash-command completion menu for the TUI input line.
;;
;; This is the live, filter-as-you-type companion to input.fnl's one-shot
;; Tab completion. While the cursor sits inside a leading slash token
;; (`^/foo`), or just past a command name in its argument region
;; (`/skills <arg>`), a small menu appears above the input listing
;; matching commands (or command-provided argument choices). The menu
;; filters as the user types, is navigable with Tab / arrows / Ctrl-P/N,
;; and commits with Tab/Enter-on-item or is dismissed with Esc.
;;
;; Design notes:
;;   * Reuses the existing `:command` register kind (its `:complete`
;;     hook) for argument completion rather than adding a new register
;;     kind \u2014 see core-parsimony guardrails.
;;   * Pure-logic helpers (candidates, filtering, navigation) are exported
;;     and driven directly by tests without termbox2. Painting is a
;;     registered `:panel` (placement :above-input) so it composes with
;;     the existing layout walker.
;;   * Menu visibility/selection live in the persistent state module so a
;;     /reload preserves an open menu; this file (RELOADABLE) owns behavior.
;;
;; Hot-reload note: in RELOADABLE; every helper is a field on M so a
;; reload that mutates the module table is picked up on the next call.

(local state (require :fen.extensions.tui.state))
(local command-registry (require :fen.core.extensions.register.command))
(local fuzzy (require :fen.util.fuzzy))

(local M {})

;; Cap on how many rows the menu shows at once (excludes the border).
(local MENU-MAX-ROWS 8)

;; @doc fen.extensions.tui.completion.ensure-defaults!
;; kind: function
;; signature: (ensure-defaults!) -> nil
;; summary: Backfill persistent completion-menu state fields after hot reloads or on first use.
;; tags: tui completion state reload
(fn M.ensure-defaults! []
  (when (= state.completion nil)
    (set state.completion {}))
  (let [c state.completion]
    (when (= c.active? nil) (set c.active? false))
    (when (= c.cursor nil) (set c.cursor 1))
    (when (= c.items nil) (set c.items []))
    (when (= c.kind nil) (set c.kind :command))
    ;; The buffer/cursor snapshot the current item list was computed for,
    ;; so we can cheaply detect when a refresh is needed.
    (when (= c.buf-snapshot nil) (set c.buf-snapshot nil))
    (when (= c.cursor-snapshot nil) (set c.cursor-snapshot nil))))

;; ---------- context detection ----------

;; @doc fen.extensions.tui.completion.context
;; kind: function
;; signature: (context buf cursor) -> ctx|nil
;; summary: Classify the slash-completion context (command name vs argument) at the cursor, or nil when not completing.
;; tags: tui completion context slash
(fn M.context [buf cursor]
  "Return a context table describing what to complete at `cursor`, or nil.

   Only fires when the buffer begins with `/` and the cursor is on that
   first logical line (no embedded newline before it). Two shapes:

     {:kind :command :prefix str :token-end n}
       cursor is within the command-name token; complete command names.

     {:kind :arg :command str :arg-prefix str :arg-start n}
       cursor is past the command name (a space separates them); ask the
       command for argument completions.

   `token-end`/`arg-start` are byte offsets used to splice replacements."
  (let [before (string.sub buf 1 cursor)]
    ;; Bail if the cursor's logical line does not start with a slash: a
    ;; newline anywhere before the cursor means we're not on the command
    ;; line, and prose never triggers the menu.
    (when (and (= (string.sub buf 1 1) "/")
               (not (string.find before "\n" 1 true)))
      (let [name-prefix (string.match before "^/([^%s]*)$")]
        (if name-prefix
            ;; Cursor is still inside the command token.
            (let [after (string.sub buf (+ cursor 1))
                  rel-space (string.find after "%s")
                  token-end (if rel-space (+ cursor (- rel-space 1)) (length buf))]
              {:kind :command :prefix name-prefix :token-end token-end})
            ;; Cursor is in the argument region: `/name <args...>` with the
            ;; cursor after the first whitespace run.
            (let [cmd (string.match before "^/([^%s]+)%s")]
              (when cmd
                ;; arg-prefix = current whitespace-delimited word under the
                ;; cursor (the token being typed), for narrowing choices.
                (let [word (or (string.match before "([^%s]*)$") "")
                      arg-start (- cursor (length word))]
                  {:kind :arg :command cmd :arg-prefix word :arg-start arg-start}))))))))

;; ---------- candidate collection ----------

(fn lower [s] (string.lower (or s "")))

(fn sort-choices! [choices]
  (table.sort choices (fn [a b]
                        (if (= (or a.rank 0) (or b.rank 0))
                            (< (lower a.label) (lower b.label))
                            (< (or a.rank 0) (or b.rank 0)))))
  choices)

(fn command-choice [cmd rank]
  {:label (tostring cmd.name)
   :value (tostring cmd.name)
   :description (or cmd.description "")
   :rank rank})

(fn command-matches-substring? [cmd needle]
  (let [needle (lower needle)
        name (lower (tostring cmd.name))
        desc (lower (or cmd.description ""))]
    (or (= needle "")
        (string.find name needle 1 true)
        (string.find desc needle 1 true))))

;; @doc fen.extensions.tui.completion.command-candidates
;; kind: function
;; signature: (command-candidates prefix) -> [Choice]
;; summary: List slash-command choices matching the typed filter, prefix-first with substring fallback.
;; tags: tui completion commands
(fn M.command-candidates [prefix]
  "Return commands matching `prefix`.

   Prefix matches are preferred so shell-style Tab behavior stays stable
   (`/e` narrows to `/errors` and `/expand`). When no command starts with
   the typed text, fall back to a case-insensitive substring search across
   names and descriptions so users can still filter by a remembered word
   (for example `/draw` can find `/redraw`)."
  (let [prefix (or prefix "")
        n (length prefix)
        prefix-out []]
    (each [_ cmd (ipairs (command-registry.list))]
      (let [name (tostring cmd.name)]
        (when (= (string.sub name 1 n) prefix)
          (table.insert prefix-out (command-choice cmd 0)))))
    (if (> (length prefix-out) 0)
        (sort-choices! prefix-out)
        (let [out []]
          (each [_ cmd (ipairs (command-registry.list))]
            (when (command-matches-substring? cmd prefix)
              (table.insert out (command-choice cmd 1))))
          (sort-choices! out)))))

;; @doc fen.extensions.tui.completion.normalize-choice
;; kind: function
;; signature: (normalize-choice choice) -> Choice|nil
;; summary: Coerce a raw completer result into a {:label :value :description} choice, or nil when it is unusable.
;; tags: tui completion arguments robustness
(fn M.normalize-choice [choice]
  "Coerce one raw completer result into a menu choice.

   Completion must stay crash-proof even with a misbehaving third-party
   completer, so this tolerates results that are not the documented
   `{:label :value :description}` table:

     * a bare string/number is treated as both label and value (a common
       ergonomic shorthand for `[\"a\" \"b\"]`);
     * a table supplies :label/:value/:description, deriving whichever is
       missing from the other so at least a label is shown;
     * anything else (boolean, function, empty/label-less table, nil) is
       dropped by returning nil."
  (if (= (type choice) :table)
      (let [label (if (not= choice.label nil) (tostring choice.label)
                      (not= choice.value nil) (tostring choice.value)
                      nil)]
        (when (and label (not= label ""))
          {:label label
           :value (if (not= choice.value nil) choice.value label)
           :description (if (not= choice.description nil)
                            (tostring choice.description) "")}))
      (or (= (type choice) :string) (= (type choice) :number))
      (let [label (tostring choice)]
        (when (not= label "")
          {:label label :value label :description ""}))
      nil))

;; @doc fen.extensions.tui.completion.arg-candidates
;; kind: function
;; signature: (arg-candidates command arg-prefix ctx) -> [Choice]
;; summary: Ask a command for argument completions, normalize them, then fuzzy-filter and rank them by the typed word.
;; tags: tui completion arguments fuzzy
(fn M.arg-candidates [command arg-prefix ctx]
  (let [raw (command-registry.arg-completions command (or arg-prefix "") ctx)
        choices []]
    (each [_ item (ipairs (or raw []))]
      (let [choice (M.normalize-choice item)]
        (when choice
          (table.insert choices choice))))
    (fuzzy.ranked (or arg-prefix "") choices
                  (fn [choice]
                    [(or choice.label "")
                     (or choice.description "")]))))

;; @doc fen.extensions.tui.completion.candidates
;; kind: function
;; signature: (candidates ctx completion-ctx) -> kind [Choice]
;; summary: Resolve completion choices for a detected context, dispatching to command or argument candidates.
;; tags: tui completion dispatch
(fn M.candidates [ctx completion-ctx]
  (if (= completion-ctx.kind :command)
      (values :command (M.command-candidates completion-ctx.prefix))
      (values :arg (M.arg-candidates completion-ctx.command
                                     completion-ctx.arg-prefix
                                     ctx))))

;; ---------- menu lifecycle ----------

(fn same-snapshot? [c buf cursor]
  (and (= c.buf-snapshot buf) (= c.cursor-snapshot cursor)))

;; @doc fen.extensions.tui.completion.refresh!
;; kind: function
;; signature: (refresh! ?ctx) -> boolean
;; summary: Recompute the completion menu from the current input buffer, opening, updating, or closing it as needed.
;; tags: tui completion refresh menu
(fn M.refresh! [?ctx]
  "Recompute menu items from the live input buffer. Opens the menu when
   there is a completion context with candidates, keeps the selection
   stable across incremental filtering, and closes it otherwise. Returns
   whether the menu is active afterward. Safe to call on every keystroke."
  (M.ensure-defaults!)
  (let [c state.completion
        buf (or state.input-buf "")
        cursor (or state.input-cursor 0)]
    (if (same-snapshot? c buf cursor)
        c.active?
        (let [comp-ctx (M.context buf cursor)]
          (set c.buf-snapshot buf)
          (set c.cursor-snapshot cursor)
          (if (= comp-ctx nil)
              (do (M.close!) false)
              (let [(kind items) (M.candidates (or ?ctx {}) comp-ctx)]
                (if (= (length items) 0)
                    (do (M.close!) false)
                    (do
                      (set c.kind kind)
                      (set c.ctx comp-ctx)
                      (set c.items items)
                      (set c.active? true)
                      (set c.cursor (math.max 1 (math.min c.cursor (length items))))
                      true))))))))

(fn clear! [c]
  (set c.active? false)
  (set c.items [])
  (set c.cursor 1)
  (set c.ctx nil))

;; @doc fen.extensions.tui.completion.close!
;; kind: function
;; signature: (close!) -> nil
;; summary: Hide the completion menu and reset its selection without touching the input buffer.
;; tags: tui completion menu dismiss
(fn M.close! []
  (M.ensure-defaults!)
  (let [c state.completion]
    (clear! c)
    ;; Force the next refresh! to recompute even at the same buffer state.
    ;; This is useful after commits: `/skills` can immediately reopen the
    ;; argument-completion menu for `/skills `.
    (set c.buf-snapshot nil)
    (set c.cursor-snapshot nil)))

;; @doc fen.extensions.tui.completion.dismiss!
;; kind: function
;; signature: (dismiss!) -> nil
;; summary: Hide the completion menu until the input buffer or cursor changes.
;; tags: tui completion menu dismiss esc
(fn M.dismiss! []
  "Hide the menu for the current buffer/cursor snapshot. Unlike close!,
   this prevents the key-dispatch tail refresh from immediately reopening
   the menu after a bare Esc / :dismiss event. The next edit or cursor
   movement changes the snapshot and makes completion available again."
  (M.ensure-defaults!)
  (let [c state.completion]
    (clear! c)
    (set c.buf-snapshot (or state.input-buf ""))
    (set c.cursor-snapshot (or state.input-cursor 0))))

;; @doc fen.extensions.tui.completion.active?
;; kind: function
;; signature: (active?) -> boolean
;; summary: Report whether the inline completion menu currently has selectable items.
;; tags: tui completion menu state
(fn M.active? []
  (M.ensure-defaults!)
  (and state.completion.active? (> (length state.completion.items) 0)))

;; ---------- navigation ----------

(fn move! [delta]
  (M.ensure-defaults!)
  (let [c state.completion
        n (length c.items)]
    (when (> n 0)
      ;; Wrap around so Tab keeps cycling through candidates.
      (set c.cursor (+ 1 (% (+ (- c.cursor 1) delta n) n))))))

;; @doc fen.extensions.tui.completion.next!
;; kind: function
;; signature: (next!) -> nil
;; summary: Advance the completion selection to the next item, wrapping at the end.
;; tags: tui completion navigation
(fn M.next! [] (move! 1))

;; @doc fen.extensions.tui.completion.prev!
;; kind: function
;; signature: (prev!) -> nil
;; summary: Move the completion selection to the previous item, wrapping at the start.
;; tags: tui completion navigation
(fn M.prev! [] (move! -1))

;; @doc fen.extensions.tui.completion.selected
;; kind: function
;; signature: (selected) -> Choice|nil
;; summary: Return the currently highlighted completion choice, or nil when the menu is empty.
;; tags: tui completion selection
(fn M.selected []
  (M.ensure-defaults!)
  (. state.completion.items state.completion.cursor))

;; @doc fen.extensions.tui.completion.selected-exact-command?
;; kind: function
;; signature: (selected-exact-command?) -> boolean
;; summary: Report whether the highlighted command is exactly the typed slash-command word.
;; tags: tui completion selection commands
(fn M.selected-exact-command? []
  "Return true when the menu is highlighting the command name already
   typed in the input buffer. Used by input Enter handling: keep the
   exact-match menu visible while typing, but submit instead of committing
   the same command and appending a space."
  (M.ensure-defaults!)
  (let [comp-ctx (M.context (or state.input-buf "") (or state.input-cursor 0))
        choice (M.selected)]
    (and state.completion.active?
         comp-ctx
         (= comp-ctx.kind :command)
         choice
         (= choice.label comp-ctx.prefix))))

;; ---------- commit ----------

(fn splice-command [name comp-ctx]
  "Replace the command-name token with `/name ` and place the cursor after."
  (let [buf state.input-buf
        after (string.sub buf (+ comp-ctx.token-end 1))
        need-space? (not (string.match after "^%s"))
        replacement (.. "/" name (if need-space? " " ""))]
    (set state.input-buf (.. replacement after))
    (set state.input-cursor (length replacement))))

(fn splice-arg [value comp-ctx]
  "Replace the current argument word with `value` and place the cursor after."
  (let [buf state.input-buf
        text (tostring value)
        before (string.sub buf 1 comp-ctx.arg-start)
        after (string.sub buf (+ comp-ctx.arg-start (length comp-ctx.arg-prefix) 1))
        need-space? (not (string.match after "^%s"))
        replacement (.. text (if need-space? " " ""))]
    (set state.input-buf (.. before replacement after))
    (set state.input-cursor (+ (length before) (length replacement)))))

;; @doc fen.extensions.tui.completion.commit!
;; kind: function
;; signature: (commit!) -> boolean
;; summary: Insert the highlighted completion into the input buffer and close the menu; returns whether anything was committed.
;; tags: tui completion commit menu
(fn M.commit! []
  "Splice the selected candidate into the input buffer. Returns true when
   a candidate was committed, false when the menu had nothing to commit."
  (M.ensure-defaults!)
  (let [c state.completion
        choice (M.selected)]
    (if (or (not c.active?) (not choice))
        false
        (do
          (if (= c.kind :command)
              (splice-command choice.value c.ctx)
              (splice-arg choice.value c.ctx))
          (M.close!)
          true))))

;; ---------- panel (paint) ----------

;; @doc fen.extensions.tui.completion.visible-window
;; kind: function
;; signature: (visible-window count cursor max-rows) -> first item-h
;; summary: Compute the scrolled slice of completion items that keeps the selected row on screen.
;; tags: tui completion viewport scroll
(fn M.visible-window [n cursor max-rows]
  (let [max-rows (math.max 1 (math.floor (or max-rows 1)))
        item-h (math.min max-rows (math.max 1 n))
        cursor (if (= n 0) 1 (math.max 1 (math.min cursor n)))
        last-first (math.max 1 (+ 1 (- n item-h)))
        first (if (<= n item-h)
                  1
                  (math.max 1 (math.min last-first (+ 1 (- cursor item-h)))))]
    (values first item-h)))

(fn fit [s w]
  (let [s (tostring (or s ""))]
    (if (> (length s) w)
        (if (> w 1) (.. (string.sub s 1 (- w 1)) "…") "…")
        s)))

;; @doc fen.extensions.tui.completion.rows
;; kind: function
;; signature: (rows w) -> [PanelRow]
;; summary: Build styled menu rows (bordered, scrolled, marked selection) for the above-input completion panel.
;; tags: tui completion panel rows
(fn M.rows [w]
  (M.ensure-defaults!)
  (let [c state.completion]
    (if (not (M.active?))
        []
        (let [w (math.max 8 (or w 80))
              items c.items
              n (length items)
              cap (math.min MENU-MAX-ROWS n)
              (first item-h) (M.visible-window n c.cursor cap)
              rows []
              label-w (do (var lw 0)
                          (for [i first (+ first item-h -1)]
                            (let [it (. items i)]
                              (when it (set lw (math.max lw (length (or it.label "")))))))
                          lw)
              inner-w (math.max 4 (- w 2))
              title (if (= c.kind :command)
                        (.. "commands (" (tostring n) ")")
                        (.. "args (" (tostring n) ")"))]
          ;; Top border with title.
          (table.insert rows {:text (fit (.. "┌─ " title " ")
                                         w)
                              :style :dim})
          (for [i first (+ first item-h -1)]
            (let [it (. items i)
                  selected? (= i c.cursor)
                  marker (if selected? "❯ " "  ")
                  label (or it.label "")
                  descr (or it.description "")
                  gap (math.max 1 (- label-w (length label)))
                  body (if (= descr "")
                           label
                           (.. label (string.rep " " gap) "  " descr))
                  text (.. "│" marker (fit body (- inner-w 1)))]
              (table.insert rows {:text text
                                  :style (if selected? :user :normal)})))
          ;; Bottom border with hint.
          (table.insert rows
                        {:text (fit (.. "└─ tab/↑↓ move · enter select · esc close")
                                    w)
                         :style :dim})
          rows))))

;; @doc fen.extensions.tui.completion.panel-spec
;; kind: function
;; signature: (panel-spec) -> PanelSpec
;; summary: Build the :above-input panel spec that renders the live completion menu when active.
;; tags: tui completion panel register
(fn M.panel-spec []
  {:name :completion
   :placement :above-input
   ;; Sit closest to the input line so it reads like an inline dropdown.
   :order 5
   :height (fn [ctx]
             (if (M.active?)
                 (length (M.rows (or (?. ctx :w) 80)))
                 0))
   :render (fn [ctx]
             (if (M.active?)
                 (M.rows (or (?. ctx :w) 80))
                 []))})

M
