;; Canonical thinking-level helpers.
;;
;; Maps fen's provider-agnostic `--thinking` levels onto the provider option
;; keys already consumed by adapters. Exact token budgets are intentionally
;; coarse buckets; `--thinking-budget` remains the Anthropic exact-control
;; escape hatch.

(local LEVELS [:off :minimal :low :medium :high :xhigh])
(local LEVEL-SET {})
(each [_ level (ipairs LEVELS)]
  (tset LEVEL-SET level true))

(local ANTHROPIC-BUDGETS
  {:off 0
   :minimal 1024
   :low 2048
   :medium 4096
   :high 8192
   :xhigh 16384})

(local OPENAI-EFFORT
  {:minimal :minimal
   :low :low
   :medium :medium
   :high :high
   :xhigh :xhigh})

(fn normalize-level [level]
  "Return a canonical keyword level, or nil when invalid/empty."
  (let [s (tostring (or level ""))]
    (if (= s "") nil
        (let [k (string.lower s)]
          (when (. LEVEL-SET k) k)))))

(fn valid-level? [level]
  (not= (normalize-level level) nil))

(fn levels [] LEVELS)

(fn level-list []
  (table.concat LEVELS ", "))

(fn openai-api? [api]
  (or (= api :openai-responses)
      (= api :openai-codex-responses)
      (= api :openai-completions)))

(fn level->provider-options [level provider-api]
  "Map a thinking level to provider options for one provider API.
   Returns `{}` for :off, unknown APIs, or invalid levels."
  (let [l (normalize-level level)]
    (if (or (= l nil) (= l :off))
        {}
        (= provider-api :anthropic-messages)
        {:thinking-budget (. ANTHROPIC-BUDGETS l)}
        (openai-api? provider-api)
        (let [effort (. OPENAI-EFFORT l)]
          (if effort {:reasoning-effort effort} {}))
        {})))

{:LEVELS LEVELS
 :normalize-level normalize-level
 :valid-level? valid-level?
 :levels levels
 :level-list level-list
 :level->provider-options level->provider-options}
