;; reload/list: an extension's manifest accounts for every module it ships
;; (reload-modules or reload-exclude), and lists no module it does not ship.

(local M {})

(fn set-of [xs]
  (collect [_ x (ipairs (or xs []))]
    (values x true)))

(fn M.check [facts]
  "facts: {:extensions [{:root :manifest-path :manifest {:reload-modules
           :reload-exclude} :modules [{:module :path}]}]}"
  (let [findings []]
    (each [_ ext (ipairs facts.extensions)]
      (let [m ext.manifest
            listed (set-of m.reload-modules)
            excluded (set-of m.reload-exclude)
            shipped (collect [_ x (ipairs ext.modules)] (values x.module true))]
        (if (= nil m.reload-modules)
            (when (< 1 (length ext.modules))
              (table.insert findings
                            {:rule :reload/list
                             :path ext.manifest-path
                             :line 1
                             :message (.. "manifest ships "
                                          (length ext.modules)
                                          " modules but declares no :reload-modules")}))
            (do
              (each [_ x (ipairs ext.modules)]
                (when (not (or (. listed x.module) (. excluded x.module)))
                  (table.insert findings
                                {:rule :reload/list
                                 :path x.path
                                 :line 1
                                 :message (.. x.module
                                              " is in neither :reload-modules nor :reload-exclude of "
                                              ext.manifest-path)})))
              (each [_ name (ipairs (icollect [k (pairs listed)] k))]
                (when (not (. shipped name))
                  (table.insert findings
                                {:rule :reload/list
                                 :path ext.manifest-path
                                 :line 1
                                 :message (.. ":reload-modules lists " name
                                              ", which this extension does not ship")})))))))
    findings))

M
