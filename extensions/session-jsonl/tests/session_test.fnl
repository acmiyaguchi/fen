;; Tests for session_jsonl.session — JSONL header + message round-trip.
;;
;; Strategy: override XDG_STATE_HOME via os.getenv monkey-patch so each test
;; gets its own temporary sessions root.

(local types (require :fen.core.types))
(local json (require :fen.util.json))
(local h (require :test_helpers))

(local make-tmpdir h.make-tmpdir)
(local rmtree h.rmtree)
(local read-all h.read-file!)

(fn count-lines [s]
  (var n 0)
  (each [_ (string.gmatch s "([^\n]+)")] (set n (+ n 1)))
  n)

(describe "extensions.session_jsonl.session"
  (fn []
    (var tmp nil)
    (var session-mod nil)

    (before_each
      (fn []
        ;; Fresh tmpdir + module reload per test so each open() picks a new
        ;; path under our overridden XDG_STATE_HOME.
        (set tmp (make-tmpdir))
        (h.stub-getenv!
          (fn [name orig]
            (if (= name :XDG_STATE_HOME) tmp
                (orig name))))
        (set session-mod (h.reload-module :fen.extensions.session_jsonl.session))))

    (after_each
      (fn []
        (h.restore-getenv!)
        (when tmp (rmtree tmp))))

    (it "does not create a file on open; writes the header on first append"
      (fn []
        (let [s (session-mod.open "/some/cwd")]
          (assert.is_table s)
          (assert.is_string s.path)
          (assert.is_string s.id)
          (assert.is_nil (h.read-file s.path))
          (session-mod.append s (types.user-message "hi"))
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

    (it "latest-for-cwd returns the most recently created non-empty file"
      (fn []
        (let [s1 (session-mod.open "/proj")]
          (session-mod.append s1 (types.user-message "first"))
          (session-mod.close s1)
          ;; ls -t orders by mtime; ensure the second file is strictly newer.
          (os.execute "sleep 1")
          (let [empty (session-mod.open "/proj")]
            (session-mod.close empty)
            (os.execute "sleep 1")
            (let [s2 (session-mod.open "/proj")]
              (session-mod.append s2 (types.user-message "second"))
              (session-mod.close s2)
              (let [latest (session-mod.latest-for-cwd "/proj")]
                (assert.are.equal s2.path latest)))))))

    (it "latest-for-cwd returns nil when no sessions exist"
      (fn []
        (let [latest (session-mod.latest-for-cwd "/never/used")]
          (assert.is_nil latest))))

    (it "reads headers and opens existing sessions without duplicating header"
      (fn []
        (let [s (session-mod.open "/p")]
          (session-mod.append s (types.user-message "before resume"))
          (session-mod.close s)
          (let [h1 (session-mod.header s.path)
                resumed (session-mod.open-existing s.path)]
            (assert.are.equal s.id h1.id)
            (session-mod.append resumed (types.user-message "after resume"))
            (session-mod.close resumed)
            (let [content (read-all s.path)
                  h2 (session-mod.header s.path)]
              (assert.are.equal s.id h2.id)
              ;; 1 header + 2 appended messages, not 2 headers + 2 messages.
              (assert.are.equal 3 (count-lines content)))))))

    (it "lists recent sessions and resolves latest/index/id/prefix/path targets"
      (fn []
        (let [s1 (session-mod.open "/proj")]
          (session-mod.append s1 (types.user-message "first chat"))
          (session-mod.close s1)
          (os.execute "sleep 1")
          (let [s2 (session-mod.open "/proj")]
            (session-mod.append s2 (types.user-message "this is the second chat title"))
            (session-mod.close s2)
            (let [items (session-mod.list-for-cwd "/proj" 10)
                  prefix (string.sub s2.id 1 8)]
              (assert.are.equal 2 (length items))
              (assert.are.equal s2.path (. items 1 :path))
              (assert.are.equal "this is the second chat title" (. items 1 :title))
              (assert.are.equal 1 (. items 1 :message-count))
              (assert.are.equal s2.path (session-mod.find "/proj" :latest))
              (assert.are.equal s2.path (session-mod.find "/proj" "0"))
              (assert.are.equal s1.path (session-mod.find "/proj" "1"))
              (assert.are.equal s2.path (session-mod.find "/proj" s2.id))
              (assert.are.equal s2.path (session-mod.find "/proj" prefix))
              (assert.are.equal s2.path (session-mod.find "/proj" s2.path)))))))

    (it "load skips malformed lines without crashing"
      (fn []
        (let [s (session-mod.open "/p")]
          (session-mod.append s (types.user-message "real"))
          (session-mod.close s)
          ;; Tack on a malformed line.
          (h.append-file s.path "not json at all\n")
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
