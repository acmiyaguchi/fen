;; Native fen_http CA bundle override tests.
;;
;; The C backend reads process environment with getenv(), so these tests
;; spawn a tiny child Fennel process with explicit env assignments instead
;; of stubbing os.getenv in the parent busted process.

(local h (require :fen.testing))

(local CHILD-SCRIPT
"(set package.cpath (.. \"packages/util/dist/?.so;\" package.cpath))\n(local socket (require :socket))\n(local fen-http (require :fen_http))\n(local server (assert (socket.bind \"127.0.0.1\" 0)))\n(server:settimeout 0)\n(let [(host port) (server:getsockname)\n      resp (fen-http.request\n             {:url (.. \"https://\" host \":\" port \"/\")\n              :method \"GET\"\n              :timeout_ms 1000\n              :connect_timeout_ms 1000})]\n  (server:close)\n  (if resp.error\n      (print (.. \"ERROR:\" resp.error))\n      (print (.. \"STATUS:\" (tostring resp.status)))))\n")

(fn run-child [env-prefix]
  (let [script (h.make-tmpfile CHILD-SCRIPT)
        cmd (.. env-prefix " fennel " (h.shellquote script) " 2>&1")
        pipe (assert (io.popen cmd :r))
        out (pipe:read :*a)]
    (pipe:close)
    (h.rm-file script)
    out))

(fn assert-ca-file-error [out]
  "A missing CURLOPT_CAINFO file should fail with a certificate-file error
   after the localhost TCP connection succeeds. Without the env override,
   this setup usually times out in TLS handshake instead."
  (assert.is_truthy (string.find out "ERROR:" 1 true)
                    (.. "expected child to return an ERROR line, got: " out))
  (assert.is_truthy (string.find (string.lower out) "cert" 1 true)
                    (.. "expected a certificate/CA-file error, got: " out)))

(describe "fen_http CA bundle override"
  (fn []
    (var tmp nil)

    (before_each (fn [] (set tmp (h.make-tmpdir))))
    (after_each (fn [] (when tmp (h.rmtree tmp))))

    (it "uses CURL_CA_BUNDLE as CURLOPT_CAINFO when set"
      (fn []
        (let [missing (.. tmp "/missing-curl-ca-bundle.pem")
              out (run-child
                    (.. "CURL_CA_BUNDLE=" (h.shellquote missing)
                        " SSL_CERT_FILE=''"))]
          (assert-ca-file-error out))))

    (it "falls back to SSL_CERT_FILE as CURLOPT_CAINFO"
      (fn []
        (let [missing (.. tmp "/missing-ssl-cert-file.pem")
              out (run-child
                    (.. "CURL_CA_BUNDLE='' SSL_CERT_FILE="
                        (h.shellquote missing)))]
          (assert-ca-file-error out))))))
