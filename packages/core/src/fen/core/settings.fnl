;; settings.json mutable preferences; deliberately separate from the models.json registry.

(local json (require :fen.util.json))
(local log (require :fen.util.log))
(local path (require :fen.util.path))
(local storage (require :fen.core.storage))

(local M {})

;; @doc fen.core.settings.config-dir
;; kind: function
;; signature: (config-dir) -> string
;; summary: Return fen's user configuration directory, honoring XDG_CONFIG_HOME through the shared path helper.
;; tags: settings config paths
(fn M.config-dir []
  (path.config-dir :fen))

;; @doc fen.core.settings.config-path
;; kind: function
;; signature: (config-path) -> string
;; summary: Return the settings.json path used for mutable user preferences such as the default provider and model.
;; tags: settings config paths
(fn M.config-path []
  (.. (M.config-dir) "/settings.json"))

(fn parse [raw p]
  (if (or (not raw) (= raw ""))
      {}
      (let [(ok? value) (pcall json.decode raw)]
        (if (and ok? (= (type value) :table))
            value
            (do (log.warn (.. "settings: malformed JSON in " p
                           ": " (tostring value)))
                {})))))

(fn normalize-pinned-tools [raw]
  "Return a de-duplicated array of pinned tool-name strings, or nil when the
   key is absent. An explicit empty array is preserved (it disables the
   default pin set)."
  (let [v raw.pinnedTools]
    (when (= (type v) :table)
      (let [out []
            seen {}]
        (each [_ name (ipairs v)]
          (let [s (and (= (type name) :string) name)]
            (when (and s (not= s "") (not (. seen s)))
              (tset seen s true)
              (table.insert out s))))
        out))))

(fn normalize [raw]
  {:default-provider raw.defaultProvider
   :default-model raw.defaultModel
   :default-thinking raw.defaultThinking
   :pinned-tools (normalize-pinned-tools raw)})

(fn raw-load [?p]
  (let [p (or ?p (M.config-path))]
    (parse (storage.read p) p)))

(fn M.load [?p]
  "Return normalized settings. Missing/malformed files return an empty record."
  (normalize (raw-load ?p)))

(fn M.save! [settings ?p]
  "Write settings atomically, preserving any unknown top-level keys already on disk."
  (let [p (or ?p (M.config-path))
        raw (raw-load p)
        s (or settings {})]
    (when (not= s.default-provider nil)
      (set raw.defaultProvider s.default-provider))
    (when (not= s.default-model nil)
      (set raw.defaultModel s.default-model))
    (when (not= s.default-thinking nil)
      (set raw.defaultThinking s.default-thinking))
    (storage.write! p (json.encode raw))
    (M.load p)))

(fn M.set-defaults! [provider model ?p]
  "Persist the default provider/model and return normalized settings."
  (M.save! {:default-provider provider :default-model model} ?p))

(fn M.adopt-default-if-unset! [provider model ?p]
  "Adopt provider/model as the default only when nothing is selected yet. Used
   by first-boot login so an explicit existing choice is never clobbered.
   Returns true when it wrote, false when an existing default was kept."
  (let [s (M.load ?p)]
    (if s.default-provider
        false
        (do (M.set-defaults! provider model ?p) true))))

(fn M.set-thinking-default! [level ?p]
  "Persist the default provider-neutral thinking level."
  (M.save! {:default-thinking level} ?p))

M
