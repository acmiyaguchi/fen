;; Tests for core.session — JSONL header + message round-trip.
;;
;; Strategy: override XDG_STATE_HOME via os.getenv monkey-patch so each test
;; gets its own temporary sessions root.

(local types (require :core.types))
(local json (require :util.json))

(local orig-getenv os.getenv)

(fn make-tmpdir []
  (let [base (os.tmpname)]
    (os.remove base)
    (assert (os.execute (.. "mkdir -p '" base "'")))
    base))

(fn rm-rf [path]
  (os.execute (.. "rm -rf '" path "'")))

(fn read-all [path]
  (let [f (assert (io.open path :r))
        content (f:read :*a)]
    (f:close)
    content))

(fn count-lines [s]
  (var n 0)
  (each [_ (string.gmatch s "([^\n]+)")] (set n (+ n 1)))
  n)

(describe "core.session"
  (fn []
    (var tmp nil)
    (var session-mod nil)

    (before_each
      (fn []
        ;; Fresh tmpdir + module reload per test so each open() picks a new
        ;; path under our overridden XDG_STATE_HOME.
        (set tmp (make-tmpdir))
        (set os.getenv (fn [name]
                         (if (= name :XDG_STATE_HOME) tmp
                             (orig-getenv name))))
        (tset package.loaded :core.session nil)
        (set session-mod (require :core.session))))

    (after_each
      (fn []
        (set os.getenv orig-getenv)
        (when tmp (rm-rf tmp))))

    (it "writes a JSONL header on open and persists the file path"
      (fn []
        (let [s (session-mod.open "/some/cwd")]
          (assert.is_table s)
          (assert.is_string s.path)
          (assert.is_string s.id)
          (session-mod.close s)
          (let [content (read-all s.path)
                first-line (string.match content "^([^\n]+)")
                header (json.decode first-line)]
            (assert.are.equal :session header.type)
            (assert.are.equal session-mod.VERSION header.version)
            (assert.are.equal "/some/cwd" header.cwd)
            (assert.are.equal s.id header.id)))))

    (it "appends one JSONL line per message"
      (fn []
        (let [s (session-mod.open "/p")
              user (types.user-message "hi")
              ass (types.assistant-message
                    {:api :openai-completions :provider :openai :model "m"
                     :content [(types.text-block "hello")]
                     :stop-reason :stop})]
          (session-mod.append s user)
          (session-mod.append s ass)
          (session-mod.close s)
          (let [content (read-all s.path)]
            ;; 1 header + 2 messages = 3 lines
            (assert.are.equal 3 (count-lines content))))))

    (it "round-trips canonical messages through load"
      (fn []
        (let [s (session-mod.open "/p")
              user (types.user-message "remember 42")
              ass (types.assistant-message
                    {:api :openai-completions :provider :openai :model "m"
                     :content [(types.text-block "got it")]
                     :stop-reason :stop})
              tr (types.tool-result-message
                   {:tool-call-id "c1" :tool-name :ls
                    :content [(types.text-block "alpha\nbeta")]
                    :is-error? false})]
          (session-mod.append s user)
          (session-mod.append s ass)
          (session-mod.append s tr)
          (session-mod.close s)
          (let [reloaded (session-mod.load s.path)]
            (assert.are.equal 3 (length reloaded))
            (assert.are.equal :user (. reloaded 1 :role))
            (assert.are.equal "remember 42" (. reloaded 1 :content))
            (assert.are.equal :assistant (. reloaded 2 :role))
            (assert.are.equal "got it" (. reloaded 2 :content 1 :text))
            (assert.are.equal :tool-result (. reloaded 3 :role))
            (assert.are.equal "c1" (. reloaded 3 :tool-call-id))))))

    (it "latest-for-cwd returns the most recently created file"
      (fn []
        (let [s1 (session-mod.open "/proj")]
          (session-mod.close s1)
          ;; ls -t orders by mtime; ensure the second file is strictly newer.
          (os.execute "sleep 1")
          (let [s2 (session-mod.open "/proj")]
            (session-mod.close s2)
            (let [latest (session-mod.latest-for-cwd "/proj")]
              (assert.are.equal s2.path latest))))))

    (it "latest-for-cwd returns nil when no sessions exist"
      (fn []
        (let [latest (session-mod.latest-for-cwd "/never/used")]
          (assert.is_nil latest))))

    (it "load skips malformed lines without crashing"
      (fn []
        (let [s (session-mod.open "/p")]
          (session-mod.append s (types.user-message "real"))
          (session-mod.close s)
          ;; Tack on a malformed line.
          (let [f (assert (io.open s.path :a))]
            (f:write "not json at all\n")
            (f:close))
          (let [reloaded (session-mod.load s.path)]
            (assert.are.equal 1 (length reloaded))))))

    (it "scopes session paths under cwd-slug"
      (fn []
        (let [s (session-mod.open "/mnt/data/foo")]
          (session-mod.close s)
          (let [root (session-mod.sessions-root "/mnt/data/foo")
                slug (session-mod.cwd-slug "/mnt/data/foo")]
            (assert.is_truthy (string.find s.path root 1 true))
            (assert.are.equal "--mnt-data-foo--" slug)))))))
