;; Thin argument and JSON protocol adapter for `fen session`.

(local flags (require :fen.cli_flags))
(local parse-util (require :fen.cli_parse))
(local json (require :fen.util.json))
(local control (require :fen.session_control))

(local M {})

(local VERBS {:new true :list true :show true :send true})

(fn invocation-error [message]
  {:ok false :error {:code :invalid_invocation :message message}})

(fn parse [argv]
  (let [verb (. argv 2)]
    (if (or (= verb :--help) (= verb :-h))
        (values {:help? true :verb :new} nil)
        (not (. VERBS verb))
        (values nil "usage: fen session <new|list|show|send> ... --json")
        (let [context (.. "session-" verb)
              opts {:session-backend :jsonl :extension-paths []
                    :extra-skill-paths []}
              positionals []
              prompt-parts []]
          (var i 3)
          (var after-separator? false)
          (var err nil)
          (while (and (<= i (length argv)) (not err))
            (let [token (. argv i)]
              (if after-separator?
                  (do (table.insert prompt-parts (tostring token))
                      (set i (+ i 1)))
                  (= token :--)
                  (do (set after-separator? true) (set i (+ i 1)))
                  (parse-util.option-token? token)
                  (let [known (flags.find-any token)
                        flag (and known (flags.find token context))]
                    (if (not flag)
                        (set err (if known
                                     (flags.invalid-message known context)
                                     (flags.unknown-message token context)))
                        (let [(next-index parse-error)
                              (parse-util.consume! opts flag argv i)]
                          (if parse-error
                              (set err parse-error)
                              (set i next-index)))))
                  (do (table.insert positionals token) (set i (+ i 1))))))
          (if err
              (values nil err)
              (do
                (set opts.verb verb)
                (set opts.session-id (. positionals 1))
                (set opts.positional-count (length positionals))
                (when (> (length prompt-parts) 0)
                  (set opts.inline-prompt (table.concat prompt-parts " ")))
                (values opts nil)))))))

(fn validate [opts]
  (if opts.help?
      nil
      (not opts.json?)
      "fen session commands require --json"
      (and (or (= opts.verb :show) (= opts.verb :send))
           (not= opts.positional-count 1))
      (.. "fen session " opts.verb " requires exactly one session id")
      (and (or (= opts.verb :new) (= opts.verb :list))
           (not= opts.positional-count 0))
      (.. "fen session " opts.verb " does not accept positional arguments")
      (and (not= opts.verb :send) opts.inline-prompt)
      "text after -- is valid only for fen session send"
      (and opts.tail
           (or (not= opts.tail (math.floor opts.tail)) (< opts.tail 0)))
      "--tail must be a non-negative integer"
      (and (= opts.verb :send)
           (> (+ (if opts.prompt 1 0)
                 (if opts.prompt-file 1 0)
                 (if opts.inline-prompt 1 0)) 1))
      "choose exactly one of --prompt, --prompt-file, or text after --"
      nil))

(fn read-prompt [opts]
  (if opts.prompt-file
      (let [(f open-error) (io.open opts.prompt-file :r)]
        (if (not f)
            (values nil (.. "cannot read --prompt-file: " (tostring open-error)))
            (let [text (f:read :*a)]
              (f:close)
              (values text nil))))
      (= opts.prompt "-")
      (values (io.read :*a) nil)
      (values (or opts.prompt opts.inline-prompt) nil)))

(fn stderr-print [...]
  (let [parts []]
    (each [_ value (ipairs [...])]
      (table.insert parts (tostring value)))
    (io.stderr:write (.. (table.concat parts "\t") "\n"))))

(fn protocol-call [f]
  "Keep ordinary Lua diagnostics off stdout while the operation is active."
  (let [old-output (io.output)
        old-stdout io.stdout
        old-print print
        old-exit os.exit]
    (io.output io.stderr)
    ;; Extensions and providers commonly consult io.stdout at call time. Point
    ;; it at stderr while the protocol operation runs; the preserved handle is
    ;; restored before emitting the sole JSON document.
    (set io.stdout io.stderr)
    (set print stderr-print)
    (set os.exit (fn [?code] (error {:__session-cli-exit true
                                     :code (or ?code 0)})))
    (let [(ok? a b) (xpcall f (fn [err]
                                (if (and (= (type err) :table)
                                         err.__session-cli-exit)
                                    err
                                    (debug.traceback (tostring err) 2))))]
      (set os.exit old-exit)
      (set print old-print)
      (set io.stdout old-stdout)
      (io.output old-output)
      (if ok?
          (values a b)
          (and (= (type a) :table) a.__session-cli-exit)
          (let [code (or a.code 1)]
            (values {:ok false
                     :error {:code (if (= code 2)
                                       :invalid_invocation
                                       :runtime_failure)
                             :message (.. "session command exited "
                                         (tostring code))}}
                    code))
          (values {:ok false
                   :error {:code :runtime_failure :message (tostring a)}} 1)))))

(fn json-ready! [result]
  "Preserve array shape for empty collection fields in the wire document."
  (when (and (= (type result) :table) result.ok)
    (when (and (= (type result.sessions) :table)
               (= (next result.sessions) nil))
      (set result.sessions json.empty-array))
    (when (and (= (type result.messages) :table)
               (= (next result.messages) nil))
      (set result.messages json.empty-array))
    (when (and (= (type (?. result :turn :messages)) :table)
               (= (next result.turn.messages) nil))
      (set result.turn.messages json.empty-array)))
  result)

(fn M.run! [argv hooks]
  (let [(opts parse-error) (parse argv)]
    (when (or parse-error (and opts (validate opts)))
      (let [message (or parse-error (validate opts))]
        (io.stdout:write (.. (json.encode (invocation-error message)) "\n"))
        (os.exit 2)))
    (when opts.help?
      (hooks.write-help!)
      (os.exit 0))
    (let [(prompt prompt-error) (if (= opts.verb :send)
                                    (read-prompt opts)
                                    (values nil nil))]
      (when (and (= opts.verb :send) (or prompt-error (not prompt) (= prompt "")))
        (io.stdout:write
          (.. (json.encode (invocation-error
                             (or prompt-error "session send requires a non-empty prompt")))
              "\n"))
        (os.exit 2))
      (let [(result exit-code)
            (protocol-call
              (fn []
                (hooks.prepare! opts (= opts.verb :send))
                (case opts.verb
                  :new (control.new opts)
                  :list (control.list opts)
                  :show (control.show opts.session-id opts)
                  :send (control.send opts.session-id prompt opts
                                      hooks.resolve-provider-config))))]
        (io.stdout:write (.. (json.encode (json-ready! result)) "\n"))
        (os.exit exit-code)))))

(tset M :parse parse)
(tset M :validate validate)

M
