(local types (require :fen.core.types))

(fn agent-result [content is-error? details]
  (let [r {:content content :is-error? (or is-error? false)}]
    (when (not= details nil) (set r.details details))
    r))

(fn ok [text]
  (agent-result [(types.text-block (or text ""))] false nil))

(fn err [message]
  (agent-result [(types.text-block (.. "error: " message))] true nil))

(fn shellquote [s]
  (.. "'" (string.gsub s "'" "'\\''") "'"))

(fn int-arg [v default]
  "Normalize integer-ish tool args."
  (let [n (tonumber v)]
    (if n (math.floor n) default)))

(fn result-text [r]
  (let [b (and r.content (. r.content 1))]
    (if (and b (= b.type :text)) b.text "")))

(fn dir-exists? [path]
  (let [pipe (io.popen (.. "test -d " (shellquote path)
                            " && echo y || echo n") :r)]
    (if (not pipe) false
        (let [out (or (pipe:read :*l) "")]
          (pipe:close)
          (= out "y")))))

{: agent-result
 : ok
 : err
 : shellquote
 : int-arg
 : result-text
 : dir-exists?}
