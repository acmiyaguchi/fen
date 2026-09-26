;; End to end (#516): the real subagent parent drives real `fen --presenter
;; rpc` children (through scripts/dev/fen-dev) against the scripted mock
;; provider. Needs FEN_BIN or `fen` on PATH, like the session CLI tests.

(local test-api (require :fen.core.extensions.test_api))
(local tool-registry (require :fen.core.extensions.register.tool))
(local events (require :fen.core.extensions.events))
(local process (require :fen.util.process))
(local clock (require :fen.util.clock))
(local testing (require :fen.testing))

(local MOCK-SCRIPT "
(fn text-of [m]
  (if (= (type m.content) :string) m.content
      (table.concat (icollect [_ b (ipairs (or m.content []))] (or b.text \"\")) \"\\n\")))
(fn [req]
  (let [all (table.concat (icollect [_ m (ipairs req.messages)] (text-of m)) \"\\n\")
        users (accumulate [n 0 _ m (ipairs req.messages)] (if (= m.role :user) (+ n 1) n))]
    (if (= req.options.tool-choice :none)
        {:text (.. \"FINAL \" (if (string.find all \"ZEBRA-7741\" 1 true) \"saw ZEBRA-7741\" \"missing fact\")
                   \" users=\" users)}
        (string.find all \"STEER-NOTE-42\" 1 true)
        {:text \"FINAL steered\"}
        (string.find all \"ORPHAN-CHECK\" 1 true)
        {:tool-call {:id \"c1\" :name :bash :args {:cmd \"sleep 37.25; echo ORPHAN-CHECK\"}}}
        (= req.turn 1)
        {:tool-call {:id \"c1\" :name :bash :args {:cmd \"cat fact.txt\"}}}
        {:tool-call {:id (.. \"c\" req.turn) :name :bash
                     :args {:cmd (.. \"sleep 0.3; echo probe \" req.turn)}}})))
")

(local UNIQUE-FACT "ZEBRA-7741: loader.fnl drops the second include")

(fn command-output [command]
  (let [pipe (assert (io.popen command :r))
        output (pipe:read :*l)]
    (pipe:close)
    output))

(fn fen-bin []
  (or (os.getenv :FEN_BIN) (command-output "command -v fen")))

(fn contains? [s needle]
  (not= nil (string.find (tostring s) needle 1 true)))

(fn orphan-pids []
  "PIDs whose command line is the e2e tool's `sleep 37.25`, scanned from
   /proc without procps. Errors when /proc cannot be read."
  (let [lfs (require :lfs)
        out []]
    (assert (lfs.attributes "/proc/self/cmdline") "orphan check needs /proc")
    (each [entry (lfs.dir "/proc")]
      (when (string.match entry "^%d+$")
        (let [f (io.open (.. "/proc/" entry "/cmdline") :rb)]
          (when f
            (let [cmdline (or (f:read :*a) "")]
              (f:close)
              (when (= cmdline "sleep\00037.25\000")
                (table.insert out entry)))))))
    out))

(fn first-text [r]
  (. r :content 1 :text))

(describe "subagent over a live rpc child #slow"
  (fn []
    (var tmp nil)
    (var saved {})
    (var spawns 0)
    (local env-names [:FEN_MOCK_SCRIPT :XDG_STATE_HOME :XDG_CONFIG_HOME :FEN_BIN])

    (before_each
      (fn []
        (set tmp (.. (os.tmpname) ".d"))
        (assert (os.execute (.. "mkdir -p " (testing.shellquote tmp) "/state "
                                (testing.shellquote tmp) "/config")))
        (testing.write-file (.. tmp "/fact.txt") (.. UNIQUE-FACT "\n"))
        (testing.write-file (.. tmp "/mock.fnl") MOCK-SCRIPT)
        (set saved {:env (collect [_ k (ipairs env-names)] (values k (or (os.getenv k) false)))
                    :process (. package.loaded :fen.util.process)
                    :runtime (. package.loaded :fen.runtime)
                    :discover (. package.loaded :fen.extensions.subagent.discover)})
        (process.setenv! :FEN_MOCK_SCRIPT (.. tmp "/mock.fnl"))
        (process.setenv! :XDG_STATE_HOME (.. tmp "/state"))
        (process.setenv! :XDG_CONFIG_HOME (.. tmp "/config"))
        (when (fen-bin) (process.setenv! :FEN_BIN (fen-bin)))
        (set spawns 0)
        (tset package.loaded :fen.util.process
              {:start-captured (fn [opts]
                                 (set spawns (+ spawns 1))
                                 (process.start-captured opts))})
        (tset package.loaded :fen.runtime
              {:binary-path (fn [] (.. (command-output "pwd") "/scripts/dev/fen-dev"))})
        (tset package.loaded :fen.extensions.subagent.discover
              {:find-agent (fn [_] {:name "e2e" :description "e2e"
                                    :provider "mock" :model "mock"
                                    :body "You are a test child."})
               :list (fn [] []) :roots (fn [] [])})
        (test-api.reset!)
        (each [_ m (ipairs [:fen.extensions.subagent :fen.extensions.subagent.runs
                            :fen.extensions.subagent.state])]
          (tset package.loaded m nil))
        ((. (require :fen.extensions.subagent) :register)
         (test-api.make-runtime-api :subagent))))

    (after_each
      (fn []
        (each [k v (pairs saved.env)]
          (process.setenv! k (or v nil)))
        (tset package.loaded :fen.util.process saved.process)
        (tset package.loaded :fen.runtime saved.runtime)
        (tset package.loaded :fen.extensions.subagent.discover saved.discover)
        (tset package.loaded :fen.extensions.subagent nil)
        (os.execute (.. "rm -rf " (testing.shellquote tmp)))))

    (fn tool []
      (accumulate [found nil _ rec (ipairs (tool-registry.merged [])) &until found]
        (when (= rec.name :subagent) rec)))

    (fn run-record [id]
      ((. (require :fen.extensions.subagent.runs) :find) id))

    (fn saw-event? [id typ]
      (accumulate [found? false _ ev (ipairs (or (?. (run-record id) :events) []))
                   &until found?]
        (= ev.type typ)))

    (it "carries a first-turn tool fact into the in-conversation finalize turn"
      (fn []
        (if (not (fen-bin))
            (pending "needs FEN_BIN or fen on PATH")
            (let [r ((. (tool) :execute)
                     {:agent :e2e :task "Find the loader bug." :cwd tmp
                      :max-tool-calls 2 :timeout-seconds 60}
                     {}
                     (fn [] (clock.sleep-ms 30)))]
              (assert.is_false r.is-error? (first-text r))
              (assert.are.equal 1 spawns)
              (assert.are.equal "FINAL saw ZEBRA-7741 users=2" (first-text r))
              (assert.is_true (. r.details :budget-finalization-requested?))
              (assert.are.equal :done (. r.details :child-exit))))))

    (it "steers a live background child without restarting it"
      (fn []
        (if (not (fen-bin))
            (pending "needs FEN_BIN or fen on PATH")
            (let [launched ((. (tool) :execute)
                            {:agent :e2e :task "Investigate." :cwd tmp
                             :timeout-seconds 60 :background true}
                            {})
                  id launched.details.run-id
                  runs (require :fen.extensions.subagent.runs)]
              (var steered? false)
              (for [_ 1 1500 &until (not= :running (. (run-record id) :status))]
                (events.emit {:type :runtime-tick})
                (when (and (not steered?) (saw-event? id :tool-result))
                  (set steered? true)
                  (runs.request-steer! id "STEER-NOTE-42: wrap up" :user))
                (clock.sleep-ms 20))
              (let [run (run-record id)]
                (assert.are.equal :completed run.status)
                (assert.are.equal "FINAL steered" run.result)
                (assert.are.equal 1 spawns)
                ;; The steer is visible in the child's own conversation.
                (assert.is_true (saw-event? id :steering-injected)))))))

    (it "cancels mid-tool and leaves no orphan process"
      (fn []
        (if (not (fen-bin))
            (pending "needs FEN_BIN or fen on PATH")
            (let [cancel {:type :cancel-marker}
                  seen {:tool? false}
                  (ok? err) (pcall (. (tool) :execute)
                                   {:agent :e2e :task "ORPHAN-CHECK" :cwd tmp
                                    :timeout-seconds 60}
                                   {}
                                   (fn []
                                     (clock.sleep-ms 30)
                                     ;; Cancel only once the scan sees the tool's
                                     ;; `sleep`, which proves the check works.
                                     (when (> (length (orphan-pids)) 0)
                                       (set seen.tool? true)
                                       (error cancel))))]
              (assert.is_true seen.tool? "orphan scan never saw the tool process")
              (assert.is_false ok?)
              (assert.are.equal cancel err)
              (assert.are.equal :cancelled (. (run-record "subagent-1") :status))
              (clock.sleep-ms 200)
              (assert.are.same [] (orphan-pids))))))))
