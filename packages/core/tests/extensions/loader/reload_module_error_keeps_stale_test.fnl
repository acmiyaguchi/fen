;; Regression for #624: a reload-module error keeps the previous version (marked :stale), does not raise, and the pass continues with later owners.

(local h (require :fen.testing))
(local test-api (require :fen.core.extensions.test_api))
(local ext-state (require :fen.core.extensions.state))

(local PROBE-MODULES [:probe.alpha_helper :probe.alpha :probe.beta])
(local SWAPPED-MODULES [:fen.core.extensions.loader
                        :fen.core.extensions.loader.discover
                        :fen.core.extensions.loader.discover.backend
                        :fen.core.settings])

(fn module-spec [name reload-modules]
  {:name name
   :dir (.. "probe:" name)
   :source :user
   :manifest {:name name
              :enabled-by-default true
              :entry-module (.. "probe." name)
              :reload-modules reload-modules}})

(fn discovered-specs []
  ;; Fresh tables per pass, like a real enumeration (discover annotates them).
  [(module-spec :alpha [:probe.alpha_helper :probe.alpha])
   (module-spec :beta [:probe.beta])])

(fn command-registrar [name ?subscribe?]
  (fn []
    {:register (fn [api]
                 (api.register :command {:name name :handler (fn [] nil)})
                 (when ?subscribe?
                   (api.on :probe-tick (fn [_] nil))))}))

(fn owner-of [command-name]
  (?. ext-state.commands-extra command-name :__owner))

(describe "#624 reload-module error during /reload"
          (fn []
            (var snapshot nil)
            (var fingerprints nil)
            (var loader nil)
            (before_each (fn []
                           (let [names []]
                             (each [_ n (ipairs SWAPPED-MODULES)]
                               (table.insert names n))
                             (each [_ n (ipairs PROBE-MODULES)]
                               (table.insert names n))
                             (set snapshot (h.package-loaded-snapshot names)))
                           (set fingerprints ext-state.reload-fingerprints)
                           (set ext-state.reload-fingerprints {})
                           (test-api.reset!)
                           (h.stub-discover-enumeration! {:enumerate (fn [_ _]
                                                                       (discovered-specs))})
                           ;; No settings.json read: every probe extension stays enabled.
                           (tset package.loaded :fen.core.settings
                                 {:load (fn [] {:extensions {}})})
                           (set loader
                                (h.reload-module :fen.core.extensions.loader))))
            (after_each (fn []
                          (each [_ n (ipairs PROBE-MODULES)]
                            (tset package.preload n nil)
                            (tset package.loaded n nil))
                          (test-api.reset!)
                          (set ext-state.reload-fingerprints fingerprints)
                          (h.restore-package-loaded! snapshot)))
            (it "keeps the failing owner's previous version stale and still reloads later owners"
                (fn []
                  (tset package.preload :probe.alpha_helper (fn [] {}))
                  (tset package.preload :probe.alpha
                        (command-registrar :alpha-cmd true))
                  (tset package.preload :probe.beta
                        (command-registrar :beta-v1))
                  (loader.load! {:extension-paths []} {:interactive? false})
                  (assert.are.equal :alpha (owner-of :alpha-cmd))
                  (assert.are.equal :loaded
                                    (?. ext-state.extensions :alpha :status))
                  ;; Edit: alpha's helper no longer loads; beta now registers beta-v2.
                  (tset package.preload :probe.alpha_helper
                        (fn []
                          (error "helper.fnl:3: unexpected closing delimiter")))
                  (tset package.preload :probe.beta
                        (command-registrar :beta-v2))
                  (let [(ok? summary) (pcall loader.load! {:extension-paths []}
                                             {:interactive? false
                                              :reload? true})]
                    (assert.is_true ok?)
                    (assert.are.equal 1 summary.failed)
                    (assert.are.equal :error (. summary.extensions 1 :status))
                    ;; alpha: old registrations stay, status is :stale with the error.
                    (assert.are.equal :alpha (owner-of :alpha-cmd))
                    (assert.are.equal :stale
                                      (?. ext-state.extensions :alpha :status))
                    (assert.is_not_nil (string.find (tostring (?. ext-state.extensions
                                                                  :alpha :error))
                                                    "probe.alpha_helper" 1 true))
                    (assert.are.equal 1
                                      (length (. ext-state.handlers :probe-tick)))
                    ;; beta: the pass continued past alpha.
                    (assert.are.equal :beta (owner-of :beta-v2))
                    (assert.is_nil (owner-of :beta-v1)))
                  ;; The single-extension reload reports (false err) instead of raising.
                  (let [(one-ok? one-err) (loader.reload-extension! :alpha)]
                    (assert.is_false one-ok?)
                    (assert.is_not_nil one-err))))))
