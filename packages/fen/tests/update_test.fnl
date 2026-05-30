(local helpers (require :fen.testing))
(local sha256 (require :fen.util.sha256))
(local json (require :fen.util.json))

(local FAKE-BIN "FAKE-FEN-BINARY-v0.0.2\n")
(local SLUG "linux-x86_64-musl-static")
(local ASSET (.. "fen-v0.0.2-" SLUG))

(fn fake-version! [version source]
  "Install a stub fen.version so the install-type gate sees what we want."
  (tset package.loaded :fen.version {:info (fn [] {: version : source})}))

(fn force-arch! []
  "Pin the asset slug so tests do not depend on the host's uname."
  (helpers.stub-getenv! (fn [name orig]
                          (if (= name :FEN_ARCH) SLUG (orig name)))))

(fn release-responder [sums-body]
  "HTTP stub that mimics the GitHub release endpoints. The asset URL
   302-redirects to a CDN host so redirect-following is exercised too."
  (fn [opts]
    (let [url opts.url]
      (if (string.find url "/releases/latest" 1 true)
          {:status 200 :body (json.encode {:tag_name "v0.0.2"})}
          (string.find url "/SHA256SUMS" 1 true)
          {:status 200 :body sums-body}
          (string.find url "cdn.example" 1 true)
          {:status 200 :body FAKE-BIN}
          (string.find url ASSET 1 true)
          {:status 302 :headers {:Location "https://cdn.example/blob"} :body ""}
          {:status 404 :body "not found"}))))

(fn load-update! []
  "Reload fen.update so it captures the currently stubbed http/version."
  (helpers.reload-module :fen.update))

(fn capture-stdout [f]
  "Run f, capturing io.write output. Returns (values result captured-text)."
  (let [out []
        real io.write]
    (set io.write (fn [...]
                    (each [_ s (ipairs [...])] (table.insert out (tostring s)))
                    io.stdout))
    (let [(ok? res) (pcall f)]
      (set io.write real)
      (assert ok? res)
      (values res (table.concat out)))))

(fn run-update-in-tmpdir [sums-body assert-fn]
  "Set up a writable tmpdir with an OLD-BINARY target, stub the release HTTP
   responses with `sums-body`, run `fen update`, and hand (code text target)
   to assert-fn. Cleans up the tmpdir afterward."
  (let [dir (helpers.make-tmpdir)
        target (.. dir "/fen")]
    (helpers.write-file target "OLD-BINARY")
    (set _G.arg {:exe target})
    (helpers.stub-http! (release-responder sums-body))
    (force-arch!)
    (fake-version! "v0.0.1" "nix")
    (let [update (load-update!)
          (code text) (capture-stdout (fn [] (update.run! [])))]
      (assert-fn code text target))
    (helpers.rmtree dir)))

(describe "fen.update"
  (fn []
    (var saved-arg nil)

    (before_each (fn [] (set saved-arg _G.arg)))

    (after_each (fn []
                  (helpers.restore-http!)
                  (helpers.restore-getenv!)
                  (tset package.loaded :fen.version nil)
                  (tset package.loaded :fen.update nil)
                  (set _G.arg saved-arg)))

    (it "maps architectures to release asset slugs"
      (fn []
        (let [update (load-update!)]
          (assert.are.equal "linux-x86_64-musl-static" (update.arch->slug :x86_64))
          (assert.are.equal "linux-x86_64-musl-static" (update.arch->slug :amd64))
          (assert.are.equal "linux-aarch64-musl-static" (update.arch->slug :aarch64))
          (assert.are.equal "linux-armv7-musleabihf-static" (update.arch->slug :armv7l))
          (assert.is_nil (update.arch->slug :mips)))))

    (it "parses SHA256SUMS entries, requiring a 64-char hex digest"
      (fn []
        (let [update (load-update!)
              h64 (string.rep "a" 64)
              sums (.. (string.rep "d" 64) "  other-file\n"
                       h64 " *" ASSET "\n")]
          (assert.are.equal h64 (update.expected-hash sums ASSET))
          (assert.is_nil (update.expected-hash sums "missing-asset"))
          ;; a short / non-64-char digest is rejected, not trusted
          (assert.is_nil (update.expected-hash (.. "abc123  " ASSET "\n") ASSET)))))

    (it "normalizes SHA256SUMS digests (uppercase, CRLF, leading space)"
      (fn []
        (let [update (load-update!)
              upper (string.rep "A" 64)
              sums (.. "  " upper " *" ASSET "\r\n")]
          (assert.are.equal (string.lower upper) (update.expected-hash sums ASSET)))))

    (it "refuses to update a source checkout"
      (fn []
        (helpers.stub-http! (release-responder ""))
        (fake-version! "v0.1.0" "source")
        (let [update (load-update!)
              code (update.run! [])]
          (assert.are.equal 1 code))))

    (it "refuses a luarocks-style install (unknown source)"
      (fn []
        (helpers.stub-http! (release-responder ""))
        ;; fen.version is a bare string for luarocks installs.
        (tset package.loaded :fen.version "v0.0.1")
        (let [update (load-update!)
              code (update.run! [])]
          (assert.are.equal 1 code))))

    (it "reads a Nix-style flat version table (no info function)"
      (fn []
        (helpers.stub-http! (release-responder ""))
        (force-arch!)
        ;; Nix/make builds ship version as a flat data table, not a module.
        (tset package.loaded :fen.version {:version "v0.0.2" :source "nix"})
        (let [update (load-update!)
              (code text) (capture-stdout (fn [] (update.run! [])))]
          (assert.are.equal 0 code)
          (assert.is_truthy (string.find text "already up to date" 1 true)))))

    (it "refuses an unreleased local build"
      (fn []
        (helpers.stub-http! (release-responder ""))
        (fake-version! "abc1234" "nix")
        (let [update (load-update!)
              code (update.run! [])]
          (assert.are.equal 1 code))))

    (it "reports already up to date when the tag matches"
      (fn []
        (helpers.stub-http! (release-responder ""))
        (force-arch!)
        (fake-version! "v0.0.2" "nix")
        (let [update (load-update!)
              (code text) (capture-stdout (fn [] (update.run! [])))]
          (assert.are.equal 0 code)
          (assert.is_truthy (string.find text "already up to date" 1 true)))))

    (it "downloads, verifies, and atomically swaps the binary"
      (fn []
        (run-update-in-tmpdir
          (.. (sha256.hex-digest FAKE-BIN) "  " ASSET "\n")
          (fn [code text target]
            (assert.are.equal 0 code)
            (assert.is_truthy (string.find text "updated to v0.0.2" 1 true))
            (assert.are.equal FAKE-BIN (helpers.read-file! target))))))

    (it "aborts on checksum mismatch without touching the binary"
      (fn []
        (run-update-in-tmpdir
          (.. (string.rep "0" 64) "  " ASSET "\n")
          (fn [code _text target]
            (assert.are.equal 1 code)
            (assert.are.equal "OLD-BINARY" (helpers.read-file! target))))))

    (it "refuses to swap when the temp write fails, leaving the binary intact"
      (fn []
        (let [dir (helpers.make-tmpdir)
              target (.. dir "/fen")
              real-open io.open]
          (helpers.write-file target "OLD-BINARY")
          (set _G.arg {:exe target})
          (helpers.stub-http! (release-responder
                                (.. (sha256.hex-digest FAKE-BIN) "  " ASSET "\n")))
          (force-arch!)
          (fake-version! "v0.0.1" "nix")
          (let [update (load-update!)]
            ;; Simulate ENOSPC: the temp handle's write reports failure.
            (set io.open (fn [p mode]
                           (if (string.find p ".fen-update" 1 true)
                               {:write (fn [_self _data] (values nil "no space left on device"))
                                :close (fn [_self] true)}
                               (real-open p mode))))
            (let [(code _text) (capture-stdout (fn [] (update.run! [])))]
              (set io.open real-open)
              (assert.are.equal 1 code)
              (assert.are.equal "OLD-BINARY" (helpers.read-file! target))))
          (helpers.rmtree dir))))))
