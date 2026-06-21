#!/usr/bin/env fennel
;; Validate intra-repo Markdown links across hand-written docs.
;;
;; For every inline [text](target) link in tracked Markdown files, checks:
;;   - relative file targets resolve to a file that exists on disk
;;   - `.md#anchor` and same-file `#anchor` targets resolve to a heading,
;;     using GitHub's heading-slug algorithm (lowercase, drop punctuation,
;;     spaces -> hyphens, dedupe repeats with -1/-2 suffixes)
;;
;; Deliberately NOT validated (skipped, not failed):
;;   - external links (http/https/mailto/... schemes, protocol-relative //)
;;   - site-only targets: `*.html` and anything under `docs/generated/`,
;;     which exist only in the generated HTML site, not the source tree
;;   - vendored docs (*/vendor/*)
;;
;; Links inside fenced code blocks (``` ... ```) are ignored. Reference-style
;; links ([text][ref]) are out of scope; only inline links are checked.
;;
;; Exits non-zero on any broken link. Mirrors check-docs.fnl in shape.

(fn read-file [path]
  (let [f (io.open path :r)]
    (when f
      (let [data (f:read :*a)] (f:close) data))))

(fn exists? [path]
  (let [f (io.open path :r)]
    (if f (do (f:close) true) false)))

(fn command-lines [cmd]
  (let [p (assert (io.popen cmd :r))
        out []]
    (each [line (p:lines)] (table.insert out line))
    (p:close)
    out))

(fn split-lines [text]
  (let [out []]
    (each [line (string.gmatch (.. text "\n") "([^\n]*)\n")]
      (table.insert out line))
    out))

(fn trim [s] (string.match s "^%s*(.-)%s*$"))

(fn dirname [path] (or (string.match path "^(.*)/[^/]*$") ""))

(fn normalize [path]
  "Collapse ./ and ../ segments in a slash path."
  (let [parts []]
    (each [seg (string.gmatch path "[^/]+")]
      (if (= seg ".") nil
          (= seg "..") (when (> (# parts) 0) (table.remove parts))
          (table.insert parts seg)))
    (table.concat parts "/")))

(fn slug [text]
  "Approximate GitHub's heading -> anchor slug."
  (let [s (string.lower text)
        s (string.gsub s "[^%w%s_-]" "")
        s (trim s)
        s (string.gsub s "%s+" "-")]
    s))

(fn fence? [line] (string.match line "^%s*```"))

(fn heading-text [line]
  ;; ATX heading: text after leading #'s, trailing #'s/whitespace dropped.
  (string.match line "^#+%s+(.-)%s*#*%s*$"))

(fn anchors-of [text]
  "Set of valid anchor slugs for a Markdown document (deduped like GitHub)."
  (let [anchors {} seen {}]
    (var in-fence false)
    (each [_ line (ipairs (split-lines text))]
      (if (fence? line) (set in-fence (not in-fence))
          (not in-fence)
          (let [ht (heading-text line)]
            (when ht
              (let [base (slug ht)
                    n (or (. seen base) 0)]
                (tset seen base (+ n 1))
                (tset anchors (if (= n 0) base (.. base "-" n)) true))))))
    anchors))

;; Cache anchor sets per resolved path (a target is often linked many times).
(local anchor-cache {})
(fn file-anchors [path]
  (when (= nil (. anchor-cache path))
    (let [text (read-file path)]
      (tset anchor-cache path (if text (anchors-of text) false))))
  (. anchor-cache path))

(fn external? [url]
  (or (string.match url "^%a[%w+.-]*:") ; scheme: http: https: mailto: tel: ...
      (string.match url "^//")))         ; protocol-relative

(fn site-only? [resolved]
  (or (string.match resolved "^docs/generated/")
      (string.match resolved "%.html$")))

(fn check-link [raw src-path src-dir line errors]
  (let [raw (trim raw)
        url (or (string.match raw "^(%S+)") raw)    ; drop optional "title"
        url (or (string.match url "^<(.-)>$") url)] ; <url> autolink form
    (when (and (not= url "") (not (external? url)))
      (let [hash (string.find url "#" 1 true)
            path (if hash (string.sub url 1 (- hash 1)) url)
            anchor (when hash (string.sub url (+ hash 1)))
            loc (.. src-path ":" line)
            md? (fn [p] (string.match p "%.md$"))]
        (if (= path "")
            ;; same-file anchor
            (when (and anchor (not= anchor ""))
              (let [anchors (file-anchors src-path)]
                (when (and anchors (not (. anchors (string.lower anchor))))
                  (table.insert errors
                    (.. loc ": broken anchor `#" anchor
                        "` — no matching heading in this file")))))
            ;; file target (with optional anchor)
            (let [resolved (normalize (.. src-dir "/" path))]
              (when (not (site-only? resolved))
                (if (not (exists? resolved))
                    (table.insert errors
                      (.. loc ": broken link `" url "` — missing file `"
                          resolved "`"))
                    (and anchor (not= anchor "") (md? resolved))
                    (let [anchors (file-anchors resolved)]
                      (when (and anchors (not (. anchors (string.lower anchor))))
                        (table.insert errors
                          (.. loc ": broken anchor `#" anchor "` in `"
                              resolved "`"))))))))))))

(fn markdown-files []
  (let [out []]
    (each [_ f (ipairs (command-lines "git ls-files '*.md'"))]
      (when (and (not (string.match f "/vendor/"))
                 (not (string.match f "^docs/generated/")))
        (table.insert out f)))
    out))

(fn main []
  (let [files (markdown-files)
        errors []]
    (var link-count 0)
    (each [_ path (ipairs files)]
      (let [text (or (read-file path) "")
            src-dir (dirname path)]
        (var in-fence false)
        (each [i line (ipairs (split-lines text))]
          (if (fence? line) (set in-fence (not in-fence))
              (not in-fence)
              (each [target (string.gmatch line "%[[^%]]*%]%(([^)]+)%)")]
                (set link-count (+ link-count 1))
                (check-link target path src-dir i errors))))))
    (when (> (# errors) 0)
      (print (.. "errors (" (# errors) "):"))
      (each [_ e (ipairs errors)] (print (.. "  " e))))
    (print (.. "Checked " link-count " links across " (# files)
               " Markdown files."))
    (if (> (# errors) 0)
        (do (print (.. "FAIL: " (# errors) " broken link"
                       (if (= (# errors) 1) "" "s")))
            (os.exit 1))
        (print "OK"))))

(main)
