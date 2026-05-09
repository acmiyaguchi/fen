;; Tests for session_jsonl.session — JSONL header + message round-trip.
;;
;; Strategy: override XDG_STATE_HOME via os.getenv monkey-patch so each test
;; gets its own temporary sessions root.

(local types (require :fen.core.types))
(local json (require :fen.util.json))
(local h (require :fen.testing))

(local make-tmpdir h.make-tmpdir)
(local rmtree h.rmtree)
(local read-all h.read-file!)

(fn count-lines [s]
  (var n 0)
  (each [_ (string.gmatch s "([^\n]+)")] (set n (+ n 1)))
  n)

(fn decode-lines [s]
  (let [out []]
    (each [line (string.gmatch s "([^\n]+)")]
      (table.insert out (json.decode line)))
    out))

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
          (let [content (read-all s.path)
                entries (decode-lines content)
                m1 (. entries 2)
                m2 (. entries 3)]
            ;; 1 header + 2 messages = 3 lines
            (assert.are.equal 3 (count-lines content))
            (assert.is_string m1.id)
            (assert.is_string m2.id)
            (assert.are.equal m1.id (. m2 :parent-id))
            (assert.are.equal :message m1.type)
            (assert.are.equal :message m2.type)))))

    (it "append-entry writes stable metadata and chains from messages"
      (fn []
        (let [s (session-mod.open "/p")]
          (let [m (session-mod.append s (types.user-message "hi"))
                custom (session-mod.append-entry s {:type :compaction
                                                    :summary "older context"
                                                    :first-kept-entry-id m.id})]
            (session-mod.close s)
            (assert.is_string custom.id)
            (assert.are.equal m.id (. custom :parent-id))
            (let [entries (decode-lines (read-all s.path))
                  e2 (. entries 2)
                  e3 (. entries 3)]
              (assert.are.equal m.id e2.id)
              (assert.are.equal custom.id e3.id)
              (assert.are.equal m.id (. e3 :parent-id))
              (assert.are.equal :compaction e3.type))))))

    (it "open-existing continues the parent-id chain"
      (fn []
        (let [s (session-mod.open "/p")]
          (let [first (session-mod.append s (types.user-message "before"))]
            (session-mod.close s)
            (let [resumed (session-mod.open-existing s.path)
                  second (session-mod.append resumed (types.user-message "after"))]
              (session-mod.close resumed)
              (assert.are.equal first.id (. second :parent-id)))))))

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
                  prefix (string.sub s2.id 1 24)]
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

    (it "load applies the latest valid compaction entry"
      (fn []
        (let [s (session-mod.open "/p")]
          (session-mod.append s (types.user-message "old one"))
          (let [kept (session-mod.append s (types.user-message "kept one"))]
            (session-mod.append s (types.assistant-message
                                    {:api :openai-completions :provider :openai :model "m"
                                     :content [(types.text-block "kept two")]
                                     :stop-reason :stop}))
            (session-mod.append-entry s {:type :compaction
                                         :summary "old summary"
                                         :first-kept-entry-id kept.id
                                         :tokens-before 100
                                         :tokens-after 20})
            (session-mod.close s)
            (let [reloaded (session-mod.load s.path)]
              (assert.are.equal 3 (length reloaded))
              (assert.are.equal :user (. reloaded 1 :role))
              (assert.are.equal :number (type (. reloaded 1 :timestamp)))
              (assert.is_not_nil (string.find (. reloaded 1 :content) "old summary" 1 true))
              (assert.are.equal "kept one" (. reloaded 2 :content))
              (assert.are.equal "kept two" (. reloaded 3 :content 1 :text))
              (assert.are.equal kept.id (. reloaded 2 :__session-entry-id))))))

    (it "load uses the latest valid compaction entry"
      (fn []
        (let [s (session-mod.open "/p")]
          (session-mod.append s (types.user-message "old one"))
          (let [middle (session-mod.append s (types.user-message "middle"))]
            (let [latest (session-mod.append s (types.user-message "latest"))]
              (session-mod.append-entry s {:type :compaction
                                           :summary "first summary"
                                           :first-kept-entry-id middle.id})
              (session-mod.append-entry s {:type :compaction
                                           :summary "latest summary"
                                           :first-kept-entry-id latest.id})
              (session-mod.close s)
              (let [reloaded (session-mod.load s.path)]
                (assert.are.equal 2 (length reloaded))
                (assert.is_not_nil (string.find (. reloaded 1 :content) "latest summary" 1 true))
                (assert.are.equal "latest" (. reloaded 2 :content)))))))

    (it "load ignores malformed compaction entries"
      (fn []
        (let [s (session-mod.open "/p")]
          (session-mod.append s (types.user-message "old one"))
          (session-mod.append-entry s {:type :compaction
                                       :summary "bad summary"
                                       :first-kept-entry-id "missing"})
          (session-mod.close s)
          (let [reloaded (session-mod.load s.path)]
            (assert.are.equal 1 (length reloaded))
            (assert.are.equal "old one" (. reloaded 1 :content))))))

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
            (assert.are.equal "--mnt-data-foo--" slug)))))))))
