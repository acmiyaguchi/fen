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
    (var cache-state nil)

    (before_each
      (fn []
        ;; Fresh tmpdir + module reload per test so each open() picks a new
        ;; path under our overridden XDG_STATE_HOME.
        (set tmp (make-tmpdir))
        (h.stub-getenv!
          (fn [name orig]
            (if (= name :XDG_STATE_HOME) tmp
                (orig name))))
        (set cache-state (require :fen.extensions.session_jsonl.state))
        (set cache-state.record-cache {})
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

    (it "durably creates and exactly resolves a header-only session"
      (fn []
        (let [s (session-mod.create "/machine")]
          (assert.is_not_nil (h.read-file s.path))
          (session-mod.close s)
          (let [found (session-mod.get "/machine" s.id)
                listed (session-mod.list-for-cwd "/machine" 10)]
            (assert.are.equal s.id found.id)
            (assert.are.equal 1 (length listed))
            (assert.are.equal 0 (. listed 1 :message-count))
            (assert.is_nil (session-mod.get "/machine" (string.sub s.id 1 8)))))))

    (it "strict machine reads reject malformed JSONL"
      (fn []
        (let [s (session-mod.create "/strict")]
          (session-mod.close s)
          (let [f (assert (io.open s.path :a))]
            (f:write "{truncated\n")
            (f:close))
          (let [(load-ok? _) (pcall session-mod.load-strict s.path)
                (transcript-ok? _) (pcall session-mod.transcript-strict s.path)]
            (assert.is_false load-ok?)
            (assert.is_false transcript-ok?)))))

    (it "reports duplicate exact session ids as ambiguous"
      (fn []
        (let [s (session-mod.create "/duplicate")]
          (session-mod.close s)
          (let [content (read-all s.path)
                duplicate (.. (session-mod.sessions-root "/duplicate") "/copy.jsonl")
                f (assert (io.open duplicate :w))]
            (f:write content)
            (f:close))
          (let [(found reason) (session-mod.get "/duplicate" s.id)]
            (assert.is_nil found)
            (assert.are.equal :ambiguous reason)))))

    (it "rejects a second per-session mutation lock until release"
      (fn []
        (let [s (session-mod.create "/locked")]
          (session-mod.close s)
          (let [release (session-mod.acquire-lock s)]
            (assert.is_function release)
            (assert.is_nil (session-mod.acquire-lock s))
            (release)
            (let [release-again (session-mod.acquire-lock s)]
              (assert.is_function release-again)
              (release-again))))))

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

    (it "returns the latest valid extension state for one owner"
      (fn []
        (let [s (session-mod.open "/p")]
          (session-mod.append-entry s {:type :extension-state
                                       :extension :goal
                                       :version 1
                                       :state {:status :running}})
          (session-mod.append-entry s {:type :extension-state
                                       :extension :plan
                                       :version 1
                                       :state {:mode :ready}})
          (session-mod.append-entry s {:type :extension-state
                                       :extension :goal
                                       :version 1
                                       :state {:status :stopped}})
          (session-mod.close s)
          (let [entry (session-mod.latest-extension-state s :goal)]
            (assert.are.equal :goal entry.extension)
            (assert.are.equal :stopped entry.state.status)))))

    (it "skips scalar JSON values across replay, metadata, and extension-state scans"
      (fn []
        (let [s (session-mod.open "/scalar")]
          (session-mod.append s (types.user-message "real"))
          (session-mod.close s)
          (h.append-file s.path "42\n\"x\"\n")
          (assert.are.equal 1 (length (session-mod.load s.path)))
          (assert.are.equal 1 (session-mod.message-count s.path))
          (assert.is_nil (session-mod.latest-extension-state s :goal)))))

    (it "ignores malformed extension-state entries and keeps the previous valid state"
      (fn []
        (let [s (session-mod.open "/p")]
          (session-mod.append-entry s {:type :extension-state
                                       :extension :goal
                                       :version 1
                                       :state {:status :running}})
          (session-mod.append-entry s {:type :extension-state
                                       :extension :goal
                                       :version 0
                                       :state {:status :stopped}})
          (session-mod.append-entry s {:type :extension-state
                                       :extension :goal
                                       :version 1
                                       :state "not a table"})
          (session-mod.append-entry s {:type :future-entry :value true})
          (session-mod.close s)
          (let [entry (session-mod.latest-extension-state s "goal")]
            (assert.are.equal :running entry.state.status)))))

    (it "discovers sessions containing extension state before the first message"
      (fn []
        (let [s (session-mod.open "/state-only")]
          (session-mod.append-entry s {:type :extension-state
                                       :extension :goal
                                       :version 1
                                       :state {:status :running}})
          (session-mod.close s)
          (assert.are.equal s.path (session-mod.latest-for-cwd "/state-only"))
          (let [items (session-mod.list-for-cwd "/state-only" 10)]
            (assert.are.equal 1 (length items))
            (assert.are.equal 0 (. items 1 :message-count))))))

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

    (it "does not let a newer unknown-only session shadow an older conversation"
      (fn []
        (let [older (session-mod.open "/proj")]
          (session-mod.append older (types.user-message "real conversation"))
          (session-mod.close older)
          (os.execute "sleep 1")
          (let [newer (session-mod.open "/proj")]
            (session-mod.append-entry newer {:type :future-entry :value true})
            (session-mod.close newer)
            (assert.are.equal older.path (session-mod.latest-for-cwd "/proj"))
            (let [items (session-mod.list-for-cwd "/proj" 10)]
              (assert.are.equal 1 (length items))
              (assert.are.equal older.path (. items 1 :path)))))))

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

    (it "caches list metadata and invalidates after appends"
      (fn []
        (let [s (session-mod.open "/proj")]
          (session-mod.append s (types.user-message "cached title"))
          (session-mod.close s)
          (let [items (session-mod.list-for-cwd "/proj" 10)
                rec (. cache-state.record-cache s.path)]
            (assert.are.equal 1 (length items))
            (assert.is_table rec)
            (assert.are.equal 1 rec.message-count)
            (assert.are.equal "cached title" rec.title)
            (let [resumed (session-mod.open-existing s.path)]
              (session-mod.append resumed (types.user-message "after cache"))
              (session-mod.close resumed)
              (assert.is_nil (. cache-state.record-cache s.path)))))))

    (it "yields while listing and loading sessions cooperatively"
      (fn []
        (let [s (session-mod.open "/proj")]
          (session-mod.append s (types.user-message "hello"))
          (session-mod.close s)
          (var yields 0)
          (let [items (session-mod.list-for-cwd "/proj" 10
                                               (fn [] (set yields (+ yields 1))))
                loaded (session-mod.load s.path
                                         (fn [] (set yields (+ yields 1))))]
            (assert.are.equal 1 (length items))
            (assert.are.equal 1 (length loaded))
            (assert.is_true (> yields 0))))))

    (it "propagates cooperative cancellation during session load"
      (fn []
        (let [s (session-mod.open "/proj")]
          (for [i 1 600]
            (session-mod.append s (types.user-message (.. "msg " (tostring i)))))
          (session-mod.close s)
          (let [(ok? err) (pcall session-mod.load s.path
                                  (fn [] (error :cancel-session-load)))]
            (assert.is_false ok?)
            (assert.is_truthy (string.find (tostring err)
                                            "cancel%-session%-load"))))))

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
            (let [transcript (session-mod.transcript s.path)
                  reloaded (session-mod.load s.path)]
              (assert.are.equal 3 (length transcript))
              (assert.are.equal "old one" (. transcript 1 :content))
              (assert.is_nil (. transcript 1 :__session-entry-id))
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
