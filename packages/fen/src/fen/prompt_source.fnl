;; Shared prompt-source selection and reading for CLI prompt entry points.
(local M {})

(fn M.count [opts inline]
  (+ (if opts.prompt 1 0) (if (and inline (> (length inline) 0)) 1 0)
     (if opts.prompt-file 1 0)))

(fn M.read [opts inline]
  (if opts.prompt-file
      (let [(f open-error) (io.open opts.prompt-file :r)]
        (if (not f)
            (values nil
                    (.. "cannot read --prompt-file: " (tostring open-error)))
            (let [text (f:read :*a)]
              (f:close)
              (values text nil))))
      (= opts.prompt "-")
      (values (io.read :*a) nil)
      (values (or opts.prompt inline) nil)))

M
