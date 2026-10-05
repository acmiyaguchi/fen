;; `--web-search` and settings `defaultWebSearch` through the real CLI entry (#574).
;; The mock provider echoes the `:web-search` option it receives, so each run
;; shows what CLI parsing, settings defaults, and agent construction delivered.

(local testing (require :fen.testing))

(local FEN-CMD "scripts/test/fen-src")
(local MOCK-ARGS
       "--extension extensions/adapters/providers/mock --provider mock --model mock")

(fn contains? [s needle]
  (not= nil (string.find s needle 1 true)))

(fn run [env args]
  (let [p (assert (io.popen (.. "env " env " " FEN-CMD " " args " 2>&1")))
        out (p:read :*a)
        (ok _why code) (p:close)]
    (values out (if (= ok true) 0 (or code 1)))))

(describe "--web-search CLI validation"
          (fn []
            (it "rejects an unknown mode with exit 2 for runs and goals"
                (fn []
                  (each [_ args (ipairs ["--web-search bogus --print hi"
                                         "goal --web-search bogus do the thing"])]
                    (let [(out code) (run "" args)]
                      (assert.are.equal 2 code)
                      (assert.is_truthy (contains? out
                                                   "invalid --web-search: bogus (expected off, cached, live)"))))))
            (it "rejects --no-tools with a searching mode"
                (fn []
                  (let [(out code) (run ""
                                        "--no-tools --web-search live --print hi")]
                    (assert.are.equal 2 code)
                    (assert.is_truthy (contains? out
                                                 "--no-tools and --web-search live cannot be combined")))))))

(describe "defaultWebSearch settings"
          (fn []
            (var tmp nil)
            (before_each (fn []
                           (set tmp (testing.make-tmpdir))
                           (testing.write-file (.. tmp "/echo.fnl")
                                               "(fn [req] (.. \"web-search=\" (tostring req.options.web-search)))")))
            (after_each (fn []
                          (when tmp (testing.rmtree tmp))))

            (fn run-mock [settings-json args]
              (when settings-json
                (testing.write-file (.. tmp "/fen/settings.json") settings-json))
              (run (.. "XDG_CONFIG_HOME=" (testing.shellquote tmp)
                       " XDG_STATE_HOME=" (testing.shellquote tmp)
                       " FEN_MOCK_SCRIPT="
                       (testing.shellquote (.. tmp "/echo.fnl")))
                   (.. MOCK-ARGS " " args " --print hi")))

            (it "applies the saved mode when the flag is absent"
                (fn []
                  (let [(out code) (run-mock "{\"defaultWebSearch\":\"cached\"}"
                                             "")]
                    (assert.are.equal 0 code out)
                    (assert.is_truthy (contains? out "web-search=cached") out))))
            (it "lets the CLI flag win over the saved mode"
                (fn []
                  (let [(out code) (run-mock "{\"defaultWebSearch\":\"cached\"}"
                                             "--web-search live")]
                    (assert.are.equal 0 code out)
                    (assert.is_truthy (contains? out "web-search=live") out))))
            (it "warns about and ignores an invalid saved mode"
                (fn []
                  (let [(out code) (run-mock "{\"defaultWebSearch\":\"on\"}" "")]
                    (assert.are.equal 0 code out)
                    (assert.is_truthy (contains? out
                                                 "settings: defaultWebSearch on is invalid; ignoring")
                                      out)
                    (assert.is_truthy (contains? out "web-search=nil") out))))
            (it "leaves the saved mode off under --no-tools instead of conflicting"
                (fn []
                  (let [(out code) (run-mock "{\"defaultWebSearch\":\"live\"}"
                                             "--no-tools")]
                    (assert.are.equal 0 code out)
                    (assert.is_truthy (contains? out "web-search=nil") out))))
            (it "accepts an explicit off alongside --no-tools"
                (fn []
                  (let [(out code) (run-mock nil "--no-tools --web-search off")]
                    (assert.are.equal 0 code out)
                    (assert.is_truthy (contains? out "web-search=off") out))))))
