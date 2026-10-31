;; Known bug #626: reloading or failing one extension leaves the registry different from a fresh start.

(local h (require :fen.testing))
(local {: known-bug} h)
(local test-api (require :fen.core.extensions.test_api))
(local ext-state (require :fen.core.extensions.state))
(local tool-registry (require :fen.core.extensions.register.tool))
(local prompt-registry (require :fen.core.extensions.register.prompt))

(local PROBE-MODULES [:probe.alpha :probe.beta])
(local SWAPPED-MODULES [:fen.core.extensions.loader
                        :fen.core.extensions.loader.discover
                        :fen.core.extensions.loader.discover.backend
                        :fen.core.settings])

(fn discovered-specs []
  (let [out []]
    (each [_ name (ipairs [:alpha :beta])]
      (table.insert out
                    {:name name
                     :dir (.. "probe:" name)
                     :source :user
                     :manifest {:name name
                                :enabled-by-default true
                                :entry-module (.. "probe." name)
                                :reload-modules [(.. "probe." name)]}}))
    out))

(local broken {})

(fn install-probe-module! [name]
  ;; Both owners claim the singleton /dup, the array tool dup_tool, and a default-order prompt fragment.
  (tset package.preload (.. "probe." name)
        (fn []
          {:register (fn [api]
                       (when (. broken name)
                         (error (.. name " register boom")))
                       (api.register :command {:name :dup :handler (fn [] nil)})
                       (api.register :tool
                                     {:name :dup_tool
                                      :parameters {:type :object}
                                      :execute (fn [] nil)})
                       (api.prompt (.. "frag-" name)))})))

(fn dup-command-owner []
  (?. ext-state.commands-extra :dup :__owner))

(fn first-dup-tool-owner []
  ;; Same first-match rule as agent.fnl's find-tool-record.
  (var found nil)
  (each [_ t (ipairs (tool-registry.merged []))]
    (when (and (= found nil) (= (tostring t.name) :dup_tool))
      (set found t.__owner)))
  found)

(describe "#626 per-owner reload drifts from fresh start"
          (fn []
            (var snapshot nil)
            (var fingerprints nil)
            (var loader nil)

            (fn fresh-start! []
              (test-api.reset!)
              (each [_ n (ipairs PROBE-MODULES)]
                (tset package.loaded n nil))
              (set loader (h.reload-module :fen.core.extensions.loader))
              (loader.load! {:extension-paths []} {:interactive? false}))

            (before_each (fn []
                           (let [names []]
                             (each [_ n (ipairs SWAPPED-MODULES)]
                               (table.insert names n))
                             (each [_ n (ipairs PROBE-MODULES)]
                               (table.insert names n))
                             (set snapshot (h.package-loaded-snapshot names)))
                           (set fingerprints ext-state.reload-fingerprints)
                           (set ext-state.reload-fingerprints {})
                           (h.stub-log-fallback! (fn [_] nil))
                           (set broken.alpha nil)
                           (set broken.beta nil)
                           (h.stub-discover-enumeration! {:enumerate (fn [_ _]
                                                                       (discovered-specs))})
                           (tset package.loaded :fen.core.settings
                                 {:load (fn [] {:extensions {}})})
                           (install-probe-module! :alpha)
                           (install-probe-module! :beta)))
            (after_each (fn []
                          (each [_ n (ipairs PROBE-MODULES)]
                            (tset package.preload n nil)
                            (tset package.loaded n nil))
                          (test-api.reset!)
                          (h.restore-log-fallback!)
                          (set ext-state.reload-fingerprints fingerprints)
                          (h.restore-package-loaded! snapshot)))
            (it "reload-extension of the shadowed owner moves the /dup winner and reorders array kinds"
                (fn []
                  (known-bug 626
                             (fn []
                               (fresh-start!)
                               (let [fresh-command (dup-command-owner)
                                     fresh-tool (first-dup-tool-owner)
                                     fresh-prompt (prompt-registry.render)
                                     (reload-ok? _) (loader.reload-extension! :alpha)]
                                 ;; Fresh start: last loaded wins the singleton, discovery order for arrays.
                                 (assert.are.equal :beta fresh-command)
                                 (assert.are.equal :alpha fresh-tool)
                                 (assert.are.equal "frag-alpha\n\nfrag-beta"
                                                   fresh-prompt)
                                 (and (= true reload-ok?)
                                      (= :alpha (dup-command-owner))
                                      (= :beta (first-dup-tool-owner))
                                      (= "frag-beta\n\nfrag-alpha"
                                         (prompt-registry.render))))))))
            (it "a failing reload of the /dup winner drops the name although the other owner still claims it"
                (fn []
                  (known-bug 626
                             (fn []
                               ;; Reference: a fresh start with beta failing resolves /dup to alpha.
                               (set broken.beta true)
                               (fresh-start!)
                               (assert.are.equal :error
                                                 (?. ext-state.extensions :beta
                                                     :status))
                               (assert.are.equal :alpha (dup-command-owner))
                               (set broken.beta nil)
                               (fresh-start!)
                               (assert.are.equal :beta (dup-command-owner))
                               (set broken.beta true)
                               (let [(reload-ok? reload-err) (loader.reload-extension! :beta)]
                                 (and (= false reload-ok?)
                                      (not= nil
                                            (string.find (tostring reload-err)
                                                         "beta register boom" 1
                                                         true))
                                      (= :loaded
                                         (?. ext-state.extensions :alpha
                                             :status))
                                      (= nil (dup-command-owner))))))))))
