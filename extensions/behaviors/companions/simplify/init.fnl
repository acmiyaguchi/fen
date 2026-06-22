;; Simplify companion extension.
;;
;; /simplify fans out read-only `simplifier` subagent reviewers over the changed
;; files (working tree, or against a ref), then has the main agent apply the safe
;; quality cleanups. Quality only — it does not hunt for bugs. The heavy lifting
;; is the model plus the existing `subagent` tool; this extension just computes
;; the changed-file set and submits a structured turn.

(local state (require :fen.extensions.simplify.state))
(local process (require :fen.util.process))
(local path (require :fen.util.path))
(local trim (. (require :fen.util.text) :trim))

(local M {})

(local SIMPLIFY_PROMPT
  (table.concat
    ["Run a simplification pass over the changed code listed below."
     "Improve reuse, simplification, efficiency, and altitude. Quality only: do NOT"
     "hunt for or fix bugs, and do NOT change behavior."
     ""
     "Process:"
     "1. For each changed file, delegate review to the `subagent` tool with agent"
     "   \"simplifier\", asking it to review that file in the current git diff for"
     "   reuse/simplification/efficiency/altitude cleanups and return findings only"
     "   (no edits). Batch sensibly when there are many files. If the `subagent`"
     "   tool or the `simplifier` agent is unavailable, review the files inline."
     "2. Consolidate the findings. Discard anything that changes behavior, is"
     "   speculative, or is really a bug fix."
     "3. Apply the safe simplifications with edit/write."
     "4. If practical, run the cheap project check: fennel scripts/test/fennel-check.fnl"
     "5. End with a concise summary: what you applied, and what you skipped and why."]
    "\n"))

(fn first-arg [args]
  (string.match (or args "") "^%s*(%S+)"))

(fn running? []
  (= state.status :running))

(fn touch! []
  (set state.updated-at (os.time)))

(fn set-status! [status]
  (set state.status status)
  (touch!))

;; --- git changed-file discovery ---------------------------------------------

(fn run-git [args]
  "Run `git <args>` in the cwd, returning captured stdout on success or nil when
   git is unavailable / not a repo so callers can fall back to model discovery."
  (let [r (process.run-captured {:cmd (.. "git " args)
                                 :cwd (path.cwd)
                                 :timeout-seconds 15}
                                nil)]
    (if (and r (= r.exit-code 0)) (or r.output "") nil)))

(fn split-lines [s]
  ;; `[^\n]+` already skips blank lines, and git emits paths verbatim, so take
  ;; each matched line as-is (no trim — a path may legitimately end in a space).
  (let [out []]
    (each [line (string.gmatch (or s "") "([^\n]+)")]
      (table.insert out line))
    out))

(fn dedupe [items]
  (let [seen {} out []]
    (each [_ it (ipairs items)]
      (when (not (. seen it))
        (tset seen it true)
        (table.insert out it)))
    out))

(fn changed-files [base]
  "List changed file paths for BASE (a ref) or the working tree vs HEAD. Returns
   nil when git could not run, so the caller can let the model discover the diff."
  (if (and base (not= base ""))
      (let [out (run-git (.. "diff --name-only " (path.shell-quote base)))]
        (when out (dedupe (split-lines out))))
      (let [tracked (run-git "diff --name-only HEAD")]
        (when tracked
          (let [files (split-lines tracked)
                untracked (run-git "ls-files --others --exclude-standard")]
            (each [_ f (ipairs (split-lines (or untracked "")))]
              (table.insert files f))
            (dedupe files))))))

(fn simplifier-agent-present? []
  ;; Reuse the subagent extension's discovery so the agent roots stay a single
  ;; source of truth. Required at call time (so a subagent reload isn't captured
  ;; stale) and pcall-guarded, so a missing module degrades to "not present" —
  ;; which simply surfaces the install hint.
  (let [(ok? discover) (pcall require :fen.extensions.subagent.discover)]
    (and ok? (not= (discover.find-agent :simplifier) nil))))

;; --- prompt + run -----------------------------------------------------------

(fn simplify-prompt [files base]
  (let [scope (if (and base (not= base ""))
                  (.. "changes since " base)
                  "uncommitted working-tree changes")
        lines [SIMPLIFY_PROMPT
               ""
               (.. "Scope: " scope ".")]]
    (if (and files (> (length files) 0))
        (do
          (table.insert lines "Changed files:")
          (each [_ f (ipairs files)]
            (table.insert lines (.. "- " f))))
        (table.insert lines (.. "The file list could not be precomputed; discover "
                                "the changed files yourself with `git diff` "
                                "(including untracked files).")))
    (table.concat lines "\n")))

(fn start-simplify! [api base run-state]
  ;; Guard first: reject a concurrent run before shelling git, so an already-busy
  ;; /simplify never pays for the (discarded) diff computation.
  (if (running?)
      (api.emit {:type :info :text "simplify: already running"})
      (let [base (trim (or base ""))
            ref (if (= base "") nil base)
            files (changed-files ref)]
        ;; Early-exit only when git succeeded and reported no changes. When git
        ;; is unavailable (files=nil) still run and let the model find the diff.
        (if (and files (= (length files) 0))
            (api.emit {:type :info :text "simplify: no changed files to simplify"})
            (do
              (when (not (simplifier-agent-present?))
                (api.emit {:type :info
                           :text (.. "simplify: no `simplifier` agent found; copy "
                                     "extensions/behaviors/companions/simplify/examples/simplifier.md "
                                     "into .fen/agents/ for isolated review "
                                     "(continuing with inline review)")}))
              (set state.last-base ref)
              (set state.last-error nil)
              (set-status! :running)
              (let [result (api.turn.submit! run-state
                                             (simplify-prompt files ref)
                                             {:when-busy :reject :emit-user? false})]
                (when (not result.ok)
                  (set state.last-error result.error)
                  (set-status! :idle)
                  (api.emit {:type :error :error (.. "/simplify: " (tostring result.error))}))
                result))))))

(fn show-summary! [api]
  (if state.last-summary
      (api.emit {:type :assistant-text
                 :text (.. "Last simplify summary:\n\n" state.last-summary)})
      (api.emit {:type :assistant-text
                 :text "No simplify run yet. Use /simplify to review and simplify the current changes."})))

(fn usage! [api]
  (api.emit {:type :assistant-text
             :text (table.concat
                     ["Usage:"
                      "/simplify         Review and apply quality cleanups on the current changes"
                      "/simplify <ref>   Simplify changes since <ref> (e.g. main)"
                      "/simplify show    Reprint the last simplify summary"]
                     "\n")}))

(fn handle-command [api args run-state]
  (let [cmd (first-arg args)
        lower (and cmd (string.lower cmd))]
    (if (or (= lower nil) (= lower ""))
        (start-simplify! api "" run-state)
        (= lower "show")
        (show-summary! api)
        (or (= lower "help") (= lower "--help") (= lower "-h"))
        (usage! api)
        ;; Anything else is treated as a base ref to diff against.
        (start-simplify! api (trim args) run-state))))

;; --- events -----------------------------------------------------------------

(fn on-turn-complete [ev]
  (when (running?)
    (if (and (= ev.status :ok) ev.result (not= ev.result ""))
        (do
          (set state.last-summary ev.result)
          (set state.last-error nil)
          (set-status! :idle))
        ;; A deliberate cancel is not a failure; leave running mode quietly.
        (= ev.status :cancelled)
        (do
          (set state.last-error nil)
          (set-status! :idle))
        (do
          (set state.last-error (or ev.error "simplify turn did not produce a summary"))
          (set-status! :idle)))))

(fn on-error [ev]
  (when (running?)
    (set state.last-error ev.error)
    (set-status! :idle)))

(fn on-reset [_]
  (set state.status :idle)
  (set state.last-error nil)
  (touch!))

(fn status-render [_ctx]
  (when (running?)
    {:text "simplify:running" :style :status}))

(fn snapshot [_ctx]
  {:status state.status
   :running? (running?)
   :last-base state.last-base
   :has-summary? (not= state.last-summary nil)
   :last-summary state.last-summary
   :last-error state.last-error
   :updated-at state.updated-at})

(fn register! [api]
  (api.register :command
    {:name :simplify
     :order 29
     :description "Review changed code and apply quality cleanups via subagent reviewers"
     :handler (fn [args run-state]
                (handle-command api args run-state))})
  (api.register :status
    {:name :simplify
     :side :left
     :order 35
     :render status-render})
  (api.register :introspect
    {:name :state
     :description "Current simplify companion status and last summary"
     :snapshot snapshot})
  (api.on :agent-turn-complete on-turn-complete)
  (api.on :error on-error)
  (api.on :reset-conversation on-reset)
  true)

(set M.register register!)
(set M.register! register!)
(set M._state state)

M
