;; Slash command dispatcher.
;;
;; Issue #15 Step 2: this module is now a thin lookup. The actual handlers
;; live as `(api.register :command {...})` registrations in
;; `core.builtin_commands` (which is required for side-effects below). Any
;; extension can register additional commands and be dispatched the same way.
;;
;; The interactive loop calls `commands.handle` via the module table each
;; turn, so /reload re-registers built-in commands on the next reload pass.

(local extensions (require :core.extensions))

;; Side-effect require: loading this module triggers the
;; `(api.register :command ...)` calls that populate the registry.
(require :core.builtin_commands)

(local M {})

(fn parse [line]
  "Split `/foo bar baz` into (\"foo\", \"bar baz\"). Returns nil for the name
   when the line is not a slash command."
  (let [stripped (string.match line "^/(.*)$")]
    (if (or (not stripped) (= stripped ""))
        (values nil "")
        (let [space-idx (string.find stripped "%s")]
          (if space-idx
              (values (string.sub stripped 1 (- space-idx 1))
                      (string.sub stripped (+ space-idx 1)))
              (values stripped ""))))))

(fn M.handle [line state]
  "Dispatch a `/`-prefixed slash command. Looks up the registered handler;
   gates `:idle-only?` commands (e.g. /new, /reload) while the agent is busy;
   pcall-isolates handler errors so a buggy command does not crash the loop."
  (let [(name args) (parse line)]
    (if (not name)
        (extensions.emit
          {:type :error :error "empty command (try /help)"})
        (let [rec (. extensions.commands-extra name)]
          (if (not rec)
              (extensions.emit
                {:type :error
                 :error (.. "unknown command: /" name " (try /help)")})
              (and rec.idle-only? state.busy?)
              (extensions.emit
                {:type :error
                 :error (.. "/" name
                            " is disabled while the agent is running")})
              (let [(ok? err) (pcall rec.handler args state)]
                (when (not ok?)
                  (extensions.emit
                    {:type :error
                     :error (.. "/" name ": " (tostring err))}))))))))

M
