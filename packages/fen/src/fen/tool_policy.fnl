;; Runtime-enforced CLI tool policy.
;;
;; Keep parsing and filtering in one reloadable module so startup validation and
;; agent construction cannot drift into different interpretations of --tools.

(local M {})

(fn requested-names [raw]
  (let [names []
        seen {}]
    (each [name (string.gmatch (tostring (or raw "")) "[^,%s]+")]
      (when (not (. seen name))
        (tset seen name true)
        (table.insert names name)))
    names))

(fn M.apply [opts tools]
  "Return the policy-filtered tool list, or nil plus a configuration error."
  (let [opts (or opts {})
        tools (or tools [])]
    (if opts.no-tools?
        []
        (not opts.tools)
        tools
        (let [names (requested-names opts.tools)]
          (if (= (length names) 0)
              (values nil "--tools must name at least one tool")
              (let [wanted {}
                    found {}
                    out []]
                (each [_ name (ipairs names)]
                  (tset wanted name true))
                (each [_ tool (ipairs tools)]
                  (let [name (tostring tool.name)]
                    (when (. wanted name)
                      (tset found name true)
                      (table.insert out tool))))
                (var missing nil)
                (each [_ name (ipairs names) &until missing]
                  (when (not (. found name))
                    (set missing name)))
                (if missing
                    (values nil (.. "unknown tool in --tools: " missing))
                    out)))))))

M
