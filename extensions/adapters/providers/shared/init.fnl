;; Shared provider-transport extension.
;;
;; This extension is a library home for code shared across the first-party
;; provider adapters (anthropic, openai). It registers no commands, tools, or
;; providers itself — provider adapters `(require :fen.extensions.provider_shared.retry)`
;; and friends. Keeping the shared transport spine here (rather than in
;; `packages/core`) keeps HTTP retry/backoff policy out of the microkernel.

(local M {})

(fn M.register [_api]
  ;; No user-facing registrations; this extension only exposes library modules.
  true)

M
