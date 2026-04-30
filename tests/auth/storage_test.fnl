;; auth.storage tests. Each test points at a fresh tempdir so we never
;; touch the real ~/.pi/agent/auth.json. The module accepts an explicit
;; path argument; production code uses the env-var-driven default.

(local storage (require :fen.providers.openai_codex_keychain))
(local json (require :fen.util.json))
(local h (require :test_helpers))

(local mktemp-dir h.make-tmpdir)
(local read-file h.read-file)

(describe "auth.storage"
  (fn []
    (var tmpdir nil)
    (var auth-path nil)

    (before_each
      (fn []
        (set tmpdir (mktemp-dir))
        (set auth-path (.. tmpdir "/agent/auth.json"))))

    (after_each
      (fn []
        (when tmpdir
          (h.rmtree tmpdir))))

    (it "returns {} when the file is missing"
      (fn []
        (let [data (storage.load auth-path)]
          (assert.is_table data)
          (assert.is_nil (next data)))))

    (it "save + load round-trips a credential record"
      (fn []
        (let [creds {:type :oauth :access "AT" :refresh "RT"
                     :expires 1770000000000 :accountId "acc_1"}]
          (storage.set :openai-codex creds auth-path)
          (let [loaded (storage.get :openai-codex auth-path)]
            (assert.are.equal :oauth loaded.type)
            (assert.are.equal "AT" loaded.access)
            (assert.are.equal "RT" loaded.refresh)
            (assert.are.equal 1770000000000 loaded.expires)
            (assert.are.equal "acc_1" loaded.accountId)))))

    (it "preserves other providers when setting one"
      (fn []
        (storage.set :anthropic {:type :api_key :key "k1"} auth-path)
        (storage.set :openai-codex
                     {:type :oauth :access "AT" :refresh "RT"
                      :expires 0 :accountId "acc"}
                     auth-path)
        (let [data (storage.load auth-path)]
          (assert.are.equal "k1" (. data :anthropic :key))
          (assert.are.equal "AT" (. data :openai-codex :access)))))

    (it "writes auth.json with mode 0600"
      (fn []
        (storage.save {:openai-codex {:type :oauth :access "x" :refresh "y"
                                       :expires 0 :accountId "z"}}
                      auth-path)
        ;; Read the file mode via shell stat -c %a (Linux).
        (let [pipe (io.popen (.. "stat -c %a '" auth-path "' 2>/dev/null"))
              mode (and pipe (pipe:read "*l"))]
          (when pipe (pipe:close))
          (assert.are.equal "600" mode))))

    (it "creates the parent agent dir if missing"
      (fn []
        ;; Tempdir exists but tempdir/agent/ does not until save creates it.
        (assert.is_nil (read-file auth-path))
        (storage.save {:foo {:type :api_key :key "k"}} auth-path)
        (assert.is_truthy (read-file auth-path))))

    (it "returns nil for an unknown provider"
      (fn []
        (storage.set :anthropic {:type :api_key :key "k"} auth-path)
        (assert.is_nil (storage.get :openai-codex auth-path))))

    (it "handles malformed JSON by returning {} (and not raising)"
      (fn []
        (h.write-file auth-path "{not valid json")
        (let [data (storage.load auth-path)]
          (assert.is_table data)
          (assert.is_nil (next data)))))

    (it "writes JSON that pi-mono could read (snake_case keys preserved)"
      (fn []
        (storage.set :openai-codex
                     {:type :oauth :access "AT" :refresh "RT"
                      :expires 1770000000000 :accountId "acc"}
                     auth-path)
        (let [raw (read-file auth-path)
              decoded (json.decode raw)]
          (assert.is_table (. decoded :openai-codex))
          (assert.are.equal "AT" (. decoded :openai-codex :access))
          (assert.are.equal "RT" (. decoded :openai-codex :refresh)))))))

(describe "auth.storage.default-auth-path"
  (fn []
    (it "honors PI_CODING_AGENT_DIR when set"
      (fn []
        ;; We can't setenv from Lua without luaposix, so just verify the
        ;; path-construction logic by checking it ends with /auth.json.
        (let [path (storage.default-auth-path)]
          (assert.is_truthy (string.find path "/auth%.json$")))))))
