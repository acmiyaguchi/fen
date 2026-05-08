;; Core user settings.
;;
;; Reads/writes `${XDG_CONFIG_HOME:-~/.config}/fen/settings.json` for small
;; user preferences that affect core startup. This is deliberately separate
;; from models.json: models.json is a provider/model registry, settings.json is
;; mutable preference state (for example the default provider/model written by
;; /model).

(local json (require :fen.util.json))
(local log (require :fen.util.log))
(local path (require :fen.util.path))

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

(fn slurp [p]
  (let [(f _) (io.open p :r)]
    (when f
      (let [s (f:read :*a)]
        (f:close)
        s))))

(fn parse [raw p]
  (if (or (not raw) (= raw ""))
      {}
      (let [(ok? value) (pcall json.decode raw)]
        (if (and ok? (= (type value) :table))
            value
            (do (log.warn (.. "settings: malformed JSON in " p
                           ": " (tostring value)))
                {})))))

(fn normalize [raw]
  (let [provider (or raw.defaultProvider raw.default-provider raw.default_provider)
        model (or raw.defaultModel raw.default-model raw.default_model)]
    {:default-provider provider
     :default-model model}))

(fn raw-load [?p]
  (let [p (or ?p (M.config-path))]
    (parse (slurp p) p)))

;; @doc fen.core.settings.load
;; kind: function
;; signature: (load ?p) -> Settings
;; summary: Load normalized user settings from settings.json, returning an empty record for missing or malformed files.
;; tags: settings config
(fn M.load [?p]
  "Return normalized settings. Missing/malformed files return an empty record."
  (normalize (raw-load ?p)))

(fn ensure-dir! [dir]
  (os.execute (.. "mkdir -p " (path.shell-quote dir) " 2>/dev/null")))

(fn atomic-write! [p content]
  (let [dir (path.dirname p)
        tmp (.. p ".tmp")]
    (ensure-dir! dir)
    (let [f (io.open tmp :w)]
      (when (not f)
        (error (.. "settings: cannot open " tmp " for write")))
      (f:write content)
      (f:close))
    (let [(ok? err) (os.rename tmp p)]
      (when (not ok?)
        (os.remove tmp)
        (error (.. "settings: rename " tmp " -> " p
                   " failed: " (tostring err)))))))

;; @doc fen.core.settings.save!
;; kind: function
;; signature: (save! settings ?p) -> Settings
;; summary: Atomically write normalized default-provider/default-model settings while preserving unknown top-level keys already on disk.
;; tags: settings config write
(fn M.save! [settings ?p]
  "Write settings atomically, preserving any unknown top-level keys already on disk."
  (let [p (or ?p (M.config-path))
        raw (raw-load p)
        s (or settings {})]
    (when (not= s.default-provider nil)
      (set raw.defaultProvider s.default-provider))
    (when (not= s.default-model nil)
      (set raw.defaultModel s.default-model))
    (atomic-write! p (json.encode raw))
    (M.load p)))

;; @doc fen.core.settings.set-defaults!
;; kind: function
;; signature: (set-defaults! provider model ?p) -> Settings
;; summary: Persist the default provider and model selected by commands, then return the normalized settings record.
;; tags: settings config models
(fn M.set-defaults! [provider model ?p]
  "Persist the default provider/model and return normalized settings."
  (M.save! {:default-provider provider :default-model model} ?p))

M
