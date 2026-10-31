;; Known bug #625: a failed reload-module's fingerprint is committed, so the next /reload restores the old code as :loaded.

(local h (require :fen.testing))
(local {: known-bug} h)
(local test-api (require :fen.core.extensions.test_api))
(local ext-state (require :fen.core.extensions.state))

(local PROBE-MODULE :probe.alpha)
(local SWAPPED-MODULES [:fen.core.extensions.loader
                        :fen.core.extensions.loader.reload
                        :fen.core.extensions.loader.discover
                        :fen.core.extensions.loader.discover.backend
                        :fen.core.settings
                        PROBE-MODULE])

(fn discovered-specs []
  [{:name :alpha
    :dir "probe:alpha"
    :source :user
    :manifest {:name :alpha
               :enabled-by-default true
               :entry-module PROBE-MODULE
               :reload-modules [PROBE-MODULE]}}])

(fn owner-of [command-name]
  (?. ext-state.commands-extra command-name :__owner))

(describe "#625 failed module fingerprint"
          (fn []
            (var snapshot nil)
            (var fingerprints nil)
            (var checksum nil)
            (var original-fingerprint nil)
            (var loader nil)
            ;; The "source on disk": its fingerprint and whether it compiles.
            (local disk {:fingerprint :v1 :broken? false})
            (before_each (fn []
                           (set snapshot
                                (h.package-loaded-snapshot SWAPPED-MODULES))
                           (set fingerprints ext-state.reload-fingerprints)
                           (set ext-state.reload-fingerprints {})
                           (set disk.fingerprint :v1)
                           (set disk.broken? false)
                           (test-api.reset!)
                           (h.stub-discover-enumeration! {:enumerate (fn [_ _]
                                                                       (discovered-specs))})
                           (tset package.loaded :fen.core.settings
                                 {:load (fn [] {:extensions {}})})
                           ;; Fresh reload module so it captures the checksum table we patch.
                           (h.reload-module :fen.core.extensions.loader.reload)
                           (set checksum (require :fen.util.checksum))
                           (set original-fingerprint
                                checksum.module-fingerprint)
                           (set checksum.module-fingerprint
                                (fn [name]
                                  (if (= name PROBE-MODULE)
                                      {:path "probe/alpha.fnl"
                                       :size 1
                                       :fingerprint disk.fingerprint}
                                      (original-fingerprint name))))
                           (tset package.preload PROBE-MODULE
                                 (fn []
                                   (when disk.broken?
                                     (error "alpha.fnl:9: unknown identifier"))
                                   {:register (fn [api]
                                                (api.register :command
                                                              {:name :alpha-v1
                                                               :handler (fn []
                                                                          nil)}))}))
                           (set loader
                                (h.reload-module :fen.core.extensions.loader))))
            (after_each (fn []
                          (set checksum.module-fingerprint original-fingerprint)
                          (tset package.preload PROBE-MODULE nil)
                          (test-api.reset!)
                          (set ext-state.reload-fingerprints fingerprints)
                          (h.restore-package-loaded! snapshot)))
            (it "reports the still-broken extension :loaded with 0 changed on the next /reload"
                (fn []
                  (known-bug 625
                             (fn []
                               (loader.load! {:extension-paths []}
                                             {:interactive? false})
                               (assert.are.equal :alpha (owner-of :alpha-v1))
                               ;; Edit alpha to a broken v2 and leave it broken on disk.
                               (set disk.fingerprint :v2)
                               (set disk.broken? true)
                               (let [(first-ok? _) (pcall loader.load!
                                                          {:extension-paths []}
                                                          {:interactive? false
                                                           :reload? true})
                                     after-first-owner (owner-of :alpha-v1)
                                     committed (. ext-state.reload-fingerprints
                                                  (.. "module:" PROBE-MODULE))
                                     (second-ok? summary) (pcall loader.load!
                                                                 {:extension-paths []}
                                                                 {:interactive? false
                                                                  :reload? true})
                                     entry (?. summary :extensions 1)
                                     (still-broken-ok? _) (pcall (. package.preload
                                                                    PROBE-MODULE))]
                                 (and (= false first-ok?)
                                      (= nil after-first-owner)
                                      ;; The failed v2 fingerprint was committed before the module ran.
                                      (= :v2 committed) (= true second-ok?)
                                      (= :loaded (?. entry :status))
                                      (= 0 (?. entry :changed))
                                      (= :loaded
                                         (?. ext-state.extensions :alpha
                                             :status))
                                      ;; Old v1 registrations came back from package.loaded...
                                      (= :alpha (owner-of :alpha-v1))
                                      ;; ...while the source is still broken.
                                      (= false still-broken-ok?)))))))))
