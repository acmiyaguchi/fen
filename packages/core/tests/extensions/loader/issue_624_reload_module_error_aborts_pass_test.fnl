;; Known bug #624: a reload-module error during /reload raises out of load! after the owner was already unregistered.

(local h (require :fen.testing))
(local {: known-bug} h)
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
            (it "drops the failing owner's registrations and status record, skips later owners, and raises from reload-extension!"
                (fn []
                  (known-bug 624
                             (fn []
                               (tset package.preload :probe.alpha_helper
                                     (fn [] {}))
                               (tset package.preload :probe.alpha
                                     (command-registrar :alpha-cmd true))
                               (tset package.preload :probe.beta
                                     (command-registrar :beta-v1))
                               (loader.load! {:extension-paths []}
                                             {:interactive? false})
                               (assert.are.equal :alpha (owner-of :alpha-cmd))
                               (assert.are.equal :beta (owner-of :beta-v1))
                               (assert.are.equal :loaded
                                                 (?. ext-state.extensions
                                                     :alpha :status))
                               (assert.are.equal 1
                                                 (length (. ext-state.handlers
                                                            :probe-tick)))
                               ;; Edit: alpha's helper no longer loads; beta now registers beta-v2.
                               (tset package.preload :probe.alpha_helper
                                     (fn []
                                       (error "helper.fnl:3: unexpected closing delimiter")))
                               (tset package.preload :probe.beta
                                     (command-registrar :beta-v2))
                               (let [(reload-ok? reload-err) (pcall loader.load!
                                                                    {:extension-paths []}
                                                                    {:interactive? false
                                                                     :reload? true})
                                     ;; Documented contract: (false err), not a raise.
                                     (one-ok? _one-err) (pcall loader.reload-extension!
                                                               :alpha)]
                                 (and (= false reload-ok?)
                                      (not= nil
                                            (string.find (tostring reload-err)
                                                         "reload probe.alpha_helper"
                                                         1 true))
                                      ;; alpha: unregistered, then never re-registered nor marked :error.
                                      (= nil (owner-of :alpha-cmd))
                                      (= nil (. ext-state.extensions :alpha))
                                      (= 0
                                         (length (or (. ext-state.handlers
                                                        :probe-tick)
                                                     [])))
                                      ;; beta: the pass stopped before reaching it.
                                      (= :beta (owner-of :beta-v1))
                                      (= nil (owner-of :beta-v2))
                                      (= false one-ok?)))))))))
