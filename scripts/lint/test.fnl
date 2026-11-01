#!/usr/bin/env fennel
;; Fixture self-test for scripts/lint: every rule must flag its bad fixture
;; with the expected count and pass its good fixture. Run by `make lint`.

(local fennel (require :fennel))
(set fennel.path (.. fennel.path ";./scripts/?.fnl;./scripts/?/init.fnl"))

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

;; rule -> findings expected from bad.fnl
(local EXPECT {:layer 1 :reload_list 3 :reload_state 3})

(var failures 0)
(each [_ rule (ipairs [:layer :reload_list :reload_state])]
  (let [check (. (require (.. :lint.rules. rule)) :check)
        bad (length (check (facts-for rule :bad)))
        good (check (facts-for rule :good))]
    (if (and (= bad (. EXPECT rule)) (= 0 (length good)))
        (print (.. "ok   lint fixture " rule))
        (do
          (set failures (+ failures 1))
          (print (string.format "FAIL lint fixture %s: bad=%d (want %d) good=%d%s"
                                rule bad (. EXPECT rule) (length good)
                                (table.concat (icollect [_ f (ipairs good)]
                                                (.. "\n  " f.message)))))))))

(when (< 0 failures) (os.exit 1))
