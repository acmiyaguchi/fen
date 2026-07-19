;; Shared application of declarative fen.cli_flags parse records.

(local M {})

(fn M.option-token? [token]
  (= (string.sub (tostring token) 1 1) "-"))

(fn apply-value! [opts flag value]
  (let [parse flag.parse
        action parse.action]
    (if (= action :read-file)
        (let [f (io.open value :r)]
          (if (not f)
              (values false (.. (or parse.read-error
                                     (.. "cannot read " flag.name))
                                 ": " value))
              (do
                (tset opts parse.dest (f:read :*a))
                (f:close)
                (values true nil))))
        (do
          (case action
            :set-value
            (tset opts parse.dest
                  (if (= parse.value-kind :number) (tonumber value) value))
            :append-value
            (table.insert (. opts parse.dest) value)
            _
            (error (.. "unsupported value flag action: " (tostring action))))
          (when parse.mark
            (tset opts parse.mark true))
          (values true nil)))))

(fn M.consume! [opts flag argv i]
  "Apply FLAG at argv index I. Returns next-index,error-message."
  (let [parse flag.parse
        action parse.action]
    (if (= action :help-all)
        (do
          (set opts.help? true)
          (set opts.help-all? true)
          (values (+ i 1) nil))
        (= flag.arg :value)
        (let [value (. argv (+ i 1))]
          (if (or (not value)
                  (and parse.value-must-not-look-like-flag?
                       (M.option-token? value)))
              (values nil (or parse.missing-message
                              (.. flag.name " requires a value")))
              (let [(ok? err) (apply-value! opts flag value)]
                (if ok?
                    (values (+ i 2) nil)
                    (values nil err)))))
        (do
          (case action
            :set-true (tset opts parse.dest true)
            :set-const (tset opts parse.dest parse.const)
            _ (error (.. "unsupported flag action: " (tostring action))))
          (when parse.mark
            (tset opts parse.mark true))
          (values (+ i 1) nil)))))

M
