#!/usr/bin/env fennel
;; Fixture self-test for scripts/lint, run by `make lint`. Each rule must
;; report exactly the expected (rule path line) findings on its bad fixture
;; and none on its good fixture; waiver parsing has its own cases.

(local fennel (require :fennel))
(set fennel.path (.. fennel.path ";./scripts/?.fnl;./scripts/?/init.fnl"))

(local waiver (require :lint.waiver))
(local DIR :scripts/lint/fixtures/)

(fn read-file [path]
  (let [f (assert (io.open path :r))
        data (f:read :*a)]
    (f:close)
    data))

(fn facts-for [rule kind]
  (let [path (.. DIR rule "/" kind ".fnl")]
    (if (= rule :reload_state)
        {:files [{: path :reloadable? true :source (read-file path)}]}
        (fennel.dofile path))))

(local RS (.. DIR "reload_state/bad.fnl"))

;; rule -> sorted "rule path:line" strings expected from bad.fnl
(local EXPECT {:layer ["layer/deps core.fnl:3"]
               :reload_list ["lint/manifest c/manifest.fnl:1"
                             "reload/list a/manifest.fnl:1"
                             "reload/list a/util.fnl:1"
                             "reload/list b/manifest.fnl:1"]
               :reload_state [(.. "reload/state " RS ":8")
                              (.. "reload/state " RS ":11")
                              (.. "reload/state " RS ":12")
                              (.. "reload/state " RS ":13")
                              (.. "reload/state " RS ":14")
                              (.. "reload/state " RS ":16")]})

(fn keys [findings]
  (let [out (icollect [_ f (ipairs findings)]
              (.. f.rule " " f.path ":" f.line))]
    (table.sort out)
    out))

(var failures 0)

(fn check! [label got want]
  (let [g (table.concat got "\n")
        w (table.concat want "\n")]
    (if (= g w)
        (print (.. "ok   lint " label))
        (do
          (set failures (+ failures 1))
          (print (.. "FAIL lint " label "\n  got:\n    "
                     (string.gsub g "\n" "\n    ") "\n  want:\n    "
                     (string.gsub w "\n" "\n    ")))))))

(each [_ rule (ipairs [:layer :reload_list :reload_state])]
  (let [check (. (require (.. :lint.rules. rule)) :check)
        want (doto (icollect [_ k (ipairs (. EXPECT rule))]
                     k)
               (table.sort))]
    (check! (.. "fixture " rule " bad") (keys (check (facts-for rule :bad)))
            want)
    (check! (.. "fixture " rule " good") (keys (check (facts-for rule :good)))
            [])))

;; A reloadable file that does not parse is a finding, not a crash.
(let [check (. (require :lint.rules.reload_state) :check)]
  (check! "parse error"
          (keys (check {:files [{:path :broken.fnl
                                 :reloadable? true
                                 :source "(local x {})\n(fn f [] (oops\n"}]}))
          ["lint/parse broken.fnl:3"]))

;; Waivers: own line (trailing) or a comment-only line above; reason required;
;; `;` inside strings and code-line-above do not count.
(let [lines ["(local x 1) ;; lint-allow r/a: trailing ok"
             ";; lint-allow r/a: above ok"
             "(code)"
             ";; lint-allow r/a"
             "(code)"
             "(print \"; lint-allow r/a: in string\")"
             "(code) ;; lint-allow r/a: covers own line only"
             "(code)"]
      at (fn [n] (tostring (waiver.for-line lines n :r/a)))]
  (check! "waivers"
          [(at 1)
           (at 3)
           (at 5)
           (at 6)
           (at 8)
           (tostring (waiver.for-line lines 3 :r/b))]
          ["trailing ok" "above ok" :no-reason :nil :nil :nil]))

(when (< 0 failures) (os.exit 1))
