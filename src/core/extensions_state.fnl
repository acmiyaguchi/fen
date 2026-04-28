;; Persistent state container for `core.extensions`.
;;
;; This module holds the live registries — bus subscriptions, contributed
;; tools/commands/presenters/hooks, system-prompt fragments, loaded
;; extension manifests, and the active presenter's ui slot. It is
;; deliberately excluded from `main.fnl`'s RELOADABLE list: re-running its
;; body would reset every registry to empty and silence all subscribers.
;; `core.extensions` (which IS reloadable) reads and writes through this
;; module, mirroring the `tui.state` ↔ `tui.tui` split.
;;
;; All fields are tables (not scalars) so identity is stable across
;; reloads of `core.extensions`. The single scalar field — the active
;; presenter's ui table — is wrapped under `:ui` as `{:slot nil}` so the
;; mutable cell still sits inside an identity-stable container.

{:version 1
 :handlers {}
 :tools-extra []
 :commands-extra {}
 :presenters []
 :hooks {:before-tool []}
 :prompt-fragments {:before-body []
                    :before-context []
                    :end []}
 :extensions {}
 :ui {:slot nil}}
