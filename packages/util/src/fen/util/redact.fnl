;; Shared diagnostic redaction for records that can be persisted or surfaced.

(local M {})
(local MAX-DEPTH 8)
(local sensitive-patterns ["auth" "authorization" "bearer" "cookie" "session"
                           "token" "secret" "password" "api-key" "api_key" "apikey"])

(fn M.sensitive-key? [key]
  "Return true when key contains a case-insensitive secret-bearing name."
  (let [name (string.lower (tostring key))]
    (var found false)
    (each [_ pattern (ipairs sensitive-patterns)]
      (when (not= nil (string.find name pattern 1 true))
        (set found true)))
    found))

(fn content-key? [key]
  (let [name (string.lower (tostring key))]
    (or (= name "message") (= name "messages") (= name "content"))))

(fn M.scrub-string [value]
  "Redact common credential shapes from an otherwise free-form string."
  (let [without-bearers (string.gsub (tostring value)
                                      "[Bb][Ee][Aa][Rr][Ee][Rr]%s+[^%s,;]+"
                                      "Bearer [redacted]")
        without-sk (string.gsub without-bearers "sk%-%w+" "[redacted]")]
    (string.gsub without-sk "([%w_%-]+)=([^%s,&;]+)"
                 (fn [key _value]
                   (if (M.sensitive-key? key)
                       (.. key "=[redacted]")
                       (.. key "=" _value))))))

(fn M.sanitize [value ?depth]
  "Return JSON-friendly data while redacting credentials and message bodies."
  (let [depth (or ?depth 0)
        kind (type value)]
    (if (> depth MAX-DEPTH) "[truncated]"
        (= kind :string) (M.scrub-string value)
        (or (= kind :number) (= kind :boolean)) value
        (= kind :nil) nil
        (= kind :table)
        (let [out {}]
          (each [key child (pairs value)]
            (when (or (= (type key) :string) (= (type key) :number))
              (tset out key (if (M.sensitive-key? key) "[redacted]"
                                (content-key? key) "[redacted]"
                                (M.sanitize child (+ depth 1))))))
          out)
        (M.scrub-string (tostring value)))))

M
