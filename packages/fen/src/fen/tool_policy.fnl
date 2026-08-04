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

(fn M.conflict-error [opts]
  "Return a CLI conflict message, if mutually exclusive tool flags coexist."
  (let [opts (or opts {})]
    (if (and opts.no-tools? opts.tools)
        "--no-tools and --tools cannot be combined"
        (and opts.no-tools? opts.denied-tools)
        "--no-tools and --denied-tools cannot be combined"
        (and opts.tools opts.denied-tools)
        "--tools and --denied-tools cannot be combined"
        nil)))

(fn policy [opts tools]
  "Resolve the filtered tools and runtime metadata in one place."
  (let [opts (or opts {})
        tools (or tools [])
        conflict (M.conflict-error opts)]
    (if conflict
        (values nil nil conflict)
        (let [raw (if opts.tools opts.tools opts.denied-tools)
              flag (if opts.tools "--tools" "--denied-tools")
              names (requested-names raw)
              named? (not= raw nil)]
          (if (and named? (= (length names) 0))
              (values nil nil (.. flag " must name at least one tool"))
              (let [wanted {}
                    found {}
                    out []]
                (each [_ name (ipairs names)]
                  (tset wanted name true))
                (each [_ tool (ipairs tools)]
                  (let [name (tostring tool.name)]
                    (when (. wanted name) (tset found name true))
                    (when (and (not opts.no-tools?)
                               (or (not named?)
                                   (and opts.tools (. wanted name))
                                   (and opts.denied-tools (not (. wanted name)))))
                      (table.insert out tool))))
                (let [missing []]
                  (each [_ name (ipairs names)]
                    (when (not (. found name)) (table.insert missing name)))
                  (if (> (length missing) 0)
                      (values nil nil
                              (.. "unknown tool name(s) in " flag ": "
                                  (table.concat missing ", ")))
                      (let [restricted {}
                            active-names {}
                            active-name-list []]
                        (each [_ tool (ipairs out)]
                          (let [name (tostring tool.name)]
                            (tset active-names name true)
                            (table.insert active-name-list name)))
                        (each [_ tool (ipairs tools)]
                          (let [name (tostring tool.name)]
                            (when (not (. active-names name))
                              (tset restricted name true))))
                        (values out
                                (when (or opts.no-tools? named?)
                                  {:flag (if opts.no-tools? "--no-tools" flag)
                                   :active-names active-name-list
                                   :total (length tools)
                                   :restricted-names restricted})
                                nil))))))))))

(fn M.apply [opts tools]
  "Return the policy-filtered tool list, or nil plus a configuration error."
  (let [(filtered _info err) (policy opts tools)]
    (values filtered err)))

(fn M.restriction-info [opts tools]
  "Return filtered-tool metadata for status and executor diagnostics."
  (let [(_filtered info err) (policy opts tools)]
    (values info err)))

M
