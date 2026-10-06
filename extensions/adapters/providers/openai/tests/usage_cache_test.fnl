(local json (require :fen.util.json))
(local path (require :fen.util.path))
(local sha256 (require :fen.util.sha256))
(local module :fen.extensions.provider_openai.usage)
(local state-name :fen.extensions.provider_openai.usage_state)
(local auth-name :fen.extensions.provider_openai.openai_codex_oauth)
(local storage-name :fen.extensions.provider_openai.openai_codex_keychain)
(local http-name :fen.util.http)

(describe "shared sanitized Codex cache"
          (fn []
            (var saved nil)
            (var dir nil)
            (var file nil)
            (var calls 0)
            (var auth-calls 0)
            (var account "private-account")

            (fn instance []
              (local state {:windows [] :failure :unavailable :cache-path file})
              (tset package.loaded state-name state)
              (tset package.loaded module nil)
              (values (require module) state))

            (fn read []
              (local f (assert (io.open file :r)))
              (local text (f:read "*a"))
              (f:close)
              text)

            (fn write [text]
              (local f (assert (io.open file :w)))
              (f:write text)
              (f:close))

            (before_each (fn []
                           (set saved {})
                           (each [_ name (ipairs [module
                                                  state-name
                                                  auth-name
                                                  storage-name
                                                  http-name])]
                             (tset saved name (. package.loaded name)))
                           (set dir (os.tmpname))
                           (os.remove dir)
                           (path.ensure-dir! dir)
                           (set file (.. dir "/codex-usage.json"))
                           (set calls 0)
                           (set auth-calls 0)
                           (set account "private-account")
                           (tset package.loaded storage-name
                                 {:get (fn [_] {:accountId account})})
                           (tset package.loaded auth-name
                                 {:get-fresh-creds! (fn [_ _opts]
                                                      (set auth-calls
                                                           (+ auth-calls 1))
                                                      {:accountId account
                                                       :access "private-token"})})
                           (tset package.loaded http-name
                                 {:request (fn [_opts]
                                             (set calls (+ calls 1))
                                             {:status 200
                                              :body (json.encode {:email "private-email"
                                                                  :account_id account
                                                                  :rate_limit {:primary_window {:used_percent 22
                                                                                                :limit_window_seconds 18000
                                                                                                :reset_at (+ (os.time)
                                                                                                             600)}}})})})))
            (after_each (fn []
                          (each [_ name (ipairs [module
                                                 state-name
                                                 auth-name
                                                 storage-name
                                                 http-name])]
                            (tset package.loaded name (. saved name)))
                          (os.execute (.. "rm -rf " (path.shell-quote dir)))))
            (it "roundtrips only sanitized fields atomically and starts stale without network"
                (fn []
                  (local (first first-state) (instance))
                  (assert.equal :fresh (. (first.refresh) :status))
                  (local text (read))
                  (assert.is_nil (string.find text "private"))
                  (local disk (json.decode text))
                  (assert.equal 1 disk.version)
                  (assert.equal (sha256.hex-digest account) disk.account-key)
                  (assert.equal 78
                                (. disk.snapshot.windows 1 :remaining-percent))
                  (assert.equal 2 (length (path.list-dir dir)))
                  (local (second second-state) (instance))
                  (local specs {})
                  (second.register {:register (fn [kind spec]
                                                (tset specs kind spec))
                                    :on (fn [_ _])})
                  (assert.equal 1 calls)
                  (assert.equal 1 auth-calls)
                  (assert.equal :stale (. (second.snapshot) :status))
                  (assert.equal :dim
                                (. (second.status (second.snapshot) 80
                                                  (os.time))
                                   :style))
                  (assert.same first-state.windows second-state.windows)
                  (assert.equal :stale (. (second.refresh) :status))
                  (assert.equal 1 calls)
                  (assert.equal 1 auth-calls)))
            (it "tolerates missing corrupt foreign-version and account-mismatched files"
                (fn []
                  (local (usage state) (instance))
                  (usage.load-cache (sha256.hex-digest account))
                  (assert.equal :unavailable (. (usage.snapshot) :status))
                  (each [_ text (ipairs ["not JSON"
                                         "[]"
                                         "null"
                                         (json.encode {:version 99
                                                       :account-key (sha256.hex-digest account)})
                                         (json.encode {:version 1
                                                       :account-key "other"
                                                       :snapshot {}})
                                         (json.encode {:version 1
                                                       :account-key (sha256.hex-digest account)
                                                       :snapshot {:windows [{:name "invalid"}]}})])]
                    (write text)
                    (usage.load-cache (sha256.hex-digest account))
                    (assert.equal :unavailable (. (usage.snapshot) :status)))
                  (usage.refresh)
                  (set account "different-account")
                  (usage.load-cache (sha256.hex-digest account))
                  (assert.same [] state.windows)
                  (assert.is_nil state.attempted-at)
                  (assert.equal 1 calls)))
            (it "persists the attempt before HTTP so another instance observes the minute floor"
                (fn []
                  (tset package.loaded http-name
                        {:request (fn [opts]
                                    (set calls (+ calls 1))
                                    (opts.yield)
                                    {:error "private-error"})})
                  (local (first _) (instance))
                  (local co (coroutine.create #(first.refresh coroutine.yield)))
                  (assert.is_true (coroutine.resume co))
                  (assert.equal 1 calls)
                  (local (second state) (instance))
                  (second.load-cache (sha256.hex-digest account))
                  (assert.is_number state.attempted-at)
                  (second.refresh)
                  (assert.equal 1 calls)
                  (assert.is_true (coroutine.resume co))
                  (local (third _) (instance))
                  (third.refresh)
                  (assert.equal :network (. (third.snapshot) :failure))
                  (assert.equal 1 calls)))
            (it "serializes simultaneous independent processes before either requests HTTP"
                (fn []
                  (local script (.. dir "/worker.lua"))
                  (local f (assert (io.open script :w)))
                  (f:write "dofile('scripts/test/busted-helper.lua')\n"
                           "local dir,id=arg[1],arg[2]\n"
                           "local clock=require('fen.util.clock')\n"
                           "package.loaded['fen.extensions.provider_openai.openai_codex_keychain']={get=function() return {accountId='shared'} end}\n"
                           "package.loaded['fen.extensions.provider_openai.openai_codex_oauth']={['get-fresh-creds!']=function() return {access='secret',accountId='shared'} end}\n"
                           "package.loaded['fen.util.http']={request=function() local f=assert(io.open(dir..'/requests','a')); f:write(id..'\\n'); f:close(); return {status=404} end}\n"
                           "local state=require('fen.extensions.provider_openai.usage_state'); state['cache-path']=dir..'/codex-usage.json'\n"
                           "local usage=require('fen.extensions.provider_openai.usage')\n"
                           "local save=usage['save-cache']; usage['save-cache']=function() clock['sleep-ms'](100); return save() end\n"
                           "local ready=assert(io.open(dir..'/ready'..id,'w')); ready:close()\n"
                           "while not io.open(dir..'/go','r') do clock['sleep-ms'](5) end\n"
                           "usage.refresh(function() clock['sleep-ms'](5) end)\n")
                  (f:close)
                  (local q (path.shell-quote dir))
                  ;; Both VMs rendezvous before refresh; the slow persistence boundary
                  ;; makes the unprotected read/check/write implementation issue two GETs.
                  (local (ok _ code)
                         (os.execute (.. "lua " (path.shell-quote script) " " q
                                         " 1 & a=$!; " "lua "
                                         (path.shell-quote script) " " q
                                         " 2 & b=$!; " "i=0; while [ ! -f " q
                                         "/ready1 ] || [ ! -f " q
                                         "/ready2 ]; do "
                                         "i=$((i+1)); if [ $i -gt 200 ]; then kill $a $b; wait; exit 1; fi; sleep 0.01; done; "
                                         "touch " q
                                         "/go; wait $a; x=$?; wait $b; y=$?; [ $x -eq 0 ] && [ $y -eq 0 ]")))
                  (assert.is_true ok (tostring code))
                  (local requests (assert (io.open (.. dir "/requests") :r)))
                  (local text (requests:read "*a"))
                  (requests:close)
                  (assert.equal 2 (length text))
                  (local disk (json.decode (read)))
                  (assert.is_number disk.snapshot.attempted-at)
                  (assert.equal :unsupported disk.snapshot.failure)))
            (it "does not request HTTP when the shared attempt cannot be persisted"
                (fn []
                  (local (usage state) (instance))
                  (local rename os.rename)
                  (set os.rename (fn [_ _] nil))
                  (local (ok err) (pcall usage.refresh))
                  (set os.rename rename)
                  (assert.is_true ok (tostring err))
                  (assert.equal 0 calls)
                  (assert.equal 0 auth-calls)
                  ;; A subsequent instance can acquire the lock after failed persistence.
                  (local (second _) (instance))
                  (second.refresh)
                  (assert.equal 1 calls)))
            (it "releases local ownership and preserves cancellation while waiting for the OS lock"
                (fn []
                  (local lfs (require :lfs))
                  (local lock lfs.lock)
                  (local (usage _) (instance))
                  (local cancelled {})
                  (set lfs.lock (fn [_ _] nil))
                  (local (ok err) (pcall usage.refresh #(error cancelled 0)))
                  (set lfs.lock lock)
                  (assert.is_false ok)
                  (assert.equal cancelled err)
                  (assert.equal 0 auth-calls)
                  (assert.equal 0 calls)
                  (local (second _) (instance))
                  (second.refresh)
                  (assert.equal 1 calls)))
            (it "failed atomic rename leaves the previous complete cache and no temporary file"
                (fn []
                  (local (usage state) (instance))
                  (usage.refresh)
                  (local original (read))
                  (local rename os.rename)
                  (set state.failure :network)
                  (set os.rename (fn [_ _] nil))
                  (local (ok err) (pcall usage.save-cache))
                  (set os.rename rename)
                  (assert.is_true ok (tostring err))
                  (assert.equal original (read))
                  (assert.equal 2 (length (path.list-dir dir)))))))
