;; defaults.json < settings.json preferences; separate from the models.json registry.

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
            (do
              (log.warn (.. "settings: malformed JSON in " p ": "
                            (tostring value)))
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

(fn object? [v]
  "True for a decoded JSON object; decoded arrays carry cjson's array metatable."
  (and (= (type v) :table) (= (getmetatable v) nil)))

(fn normalize-extensions [raw]
  "Map extension name -> that extension's settings object; other entries are dropped."
  (let [out {}]
    (when (object? raw.extensions)
      (each [name v (pairs raw.extensions)]
        (when (and (= (type name) :string) (object? v))
          (tset out name v))))
    out))

(fn normalize [raw]
  {:default-provider raw.defaultProvider
   :default-model raw.defaultModel
   :default-thinking raw.defaultThinking
   :default-web-search raw.defaultWebSearch
   :pinned-tools (normalize-pinned-tools raw)
   :extensions (normalize-extensions raw)})

(fn raw-load [?p]
  (let [p (or ?p (M.config-path))]
    (parse (storage.read p) p)))

(fn merge [base override]
  "Merge only JSON objects; arrays, scalars, false, and null replace wholesale."
  (if (and (object? base) (object? override))
      (let [out {}]
        (each [k v (pairs base)]
          (tset out k v))
        (each [k v (pairs override)]
          (tset out k (merge (. base k) v)))
        out)
      override))

(fn M.load [?p]
  "Return normalized defaults.json overlaid by mutable settings.json.
   Missing/malformed files contribute an empty record. ?p overrides only the
   mutable document path; declarative defaults always use the config directory."
  (normalize (merge (raw-load (.. (M.config-dir) "/defaults.json"))
                    (raw-load ?p))))

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
   by first-boot login so an existing mutable or declarative choice is never clobbered.
   Returns true when it wrote, false when an existing default was kept."
  (let [s (M.load ?p)]
    (if s.default-provider
        false
        (do
          (M.set-defaults! provider model ?p)
          true))))

(fn M.set-thinking-default! [level ?p]
  "Persist the default provider-neutral thinking level."
  (M.save! {:default-thinking level} ?p))

;; @doc fen.core.settings.extension
;; kind: function
;; signature: (extension name ?path) -> table
;; summary: Return extension `name`'s merged `extensions.<name>` settings without the loader-owned `enabled` flag, or {}.
;; tags: settings extensions
(fn M.extension [name ?p]
  (let [out {}]
    (each [k v (pairs (or (. (M.load ?p) :extensions name) {}))]
      (when (not= k :enabled)
        (tset out k v)))
    out))

(fn M.set-extension-enabled! [name enabled? ?p]
  "Persist `extensions.<name>.enabled`, preserving every other key on disk."
  (let [p (or ?p (M.config-path))
        raw (raw-load p)]
    (when (not (object? raw.extensions))
      (set raw.extensions {}))
    (when (not (object? (. raw.extensions name)))
      (tset raw.extensions name {}))
    (tset raw.extensions name :enabled enabled?)
    (storage.write! p (json.encode raw))
    (M.load p)))

M
