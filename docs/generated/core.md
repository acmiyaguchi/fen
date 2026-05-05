# Fen core API

Generated from Fennel sources. Each module section lists exported
functions in source order. Items with an inline `;; @doc` block
include their summary and signature; undocumented items show their
name only.

Run `make docs` to regenerate.

## fen.core.agent

### `fen.core.agent.make-agent`
`(make-agent {:provider-name :model :system :tools :api-key :on-event :max-tokens :convert-to-llm :provider-options}) -> Agent`
Construct an Agent record with empty messages, ready for repeated step calls. :api-key and :max-tokens are auto-injected into provider-options. :convert-to-llm projects custom AgentMessages onto canonical Messages before each provider call.
*tags:* agent, loop
_packages/core/src/fen/core/agent.fnl:46_

### `fen.core.agent.step`
`(step agent user-msg ?cancel-fn) -> string`
Run one user turn. Appends a UserMessage, then iterates provider-call -> tool-execution until a non-tool stop reason or the safety cap. Cooperative yields when called inside a coroutine; ?cancel-fn polled at every yield.
*tags:* agent, loop, step
_packages/core/src/fen/core/agent.fnl:349_

### `fen.core.agent.SAFETY-CAP`
`number`
Hard ceiling on tool-call iterations per step. Bump if a real workflow needs more, don't remove.
*tags:* agent, loop, limits
_packages/core/src/fen/core/agent.fnl:14_

## fen.core.docs.contracts

### `fen.core.docs.contracts.types`
_packages/core/src/fen/core/docs/contracts.fnl:15_

### `fen.core.docs.contracts.register-kinds`
_packages/core/src/fen/core/docs/contracts.fnl:15_

### `fen.core.docs.contracts.events`
_packages/core/src/fen/core/docs/contracts.fnl:15_

### `fen.core.docs.contracts.interfaces`
_packages/core/src/fen/core/docs/contracts.fnl:15_

## fen.core.extensions

### `fen.core.extensions.version`
_packages/core/src/fen/core/extensions/init.fnl:26_

### `fen.core.extensions.handlers`
_packages/core/src/fen/core/extensions/init.fnl:27_

### `fen.core.extensions.tools-extra`
_packages/core/src/fen/core/extensions/init.fnl:28_

### `fen.core.extensions.commands-extra`
_packages/core/src/fen/core/extensions/init.fnl:29_

### `fen.core.extensions.controls-extra`
_packages/core/src/fen/core/extensions/init.fnl:30_

### `fen.core.extensions.status-extra`
_packages/core/src/fen/core/extensions/init.fnl:31_

### `fen.core.extensions.presenters`
_packages/core/src/fen/core/extensions/init.fnl:32_

### `fen.core.extensions.providers`
_packages/core/src/fen/core/extensions/init.fnl:33_

### `fen.core.extensions.auth-backends`
_packages/core/src/fen/core/extensions/init.fnl:34_

### `fen.core.extensions.session-backends`
_packages/core/src/fen/core/extensions/init.fnl:35_

### `fen.core.extensions.session`
_packages/core/src/fen/core/extensions/init.fnl:36_

### `fen.core.extensions.hooks`
_packages/core/src/fen/core/extensions/init.fnl:37_

### `fen.core.extensions.extensions`
_packages/core/src/fen/core/extensions/init.fnl:38_

### `fen.core.extensions.ui`
_packages/core/src/fen/core/extensions/init.fnl:39_

### `fen.core.extensions.emit`
`(emit ev) -> nil`
Dispatch ev to handlers[ev.type] and the `:*` wildcard bucket.
*tags:* events, bus
_packages/core/src/fen/core/extensions/init.fnl:46_

### `fen.core.extensions.on`
`(on event-name handler ?owner) -> unsubscribe-fn`
Subscribe handler to event-name. Owner-tagged handlers are removed by unregister-by-owner.
*tags:* events, bus, subscribe
_packages/core/src/fen/core/extensions/init.fnl:53_

### `fen.core.extensions.register`
`(register kind spec owner) -> {:kind :name :owner :unregister}`
Register a contribution under the given kind. See contracts.register-kinds for the kind list.
*tags:* extensions, register
_packages/core/src/fen/core/extensions/init.fnl:60_

### `fen.core.extensions.dispatch-command`
`(dispatch-command line caller-state) -> nil`
Look up and pcall-isolate a registered slash command. Emits :error on failure.
*tags:* commands
_packages/core/src/fen/core/extensions/init.fnl:68_

### `fen.core.extensions.prompt`
`(prompt text-or-fn ?opts owner) -> {:kind :name :owner :unregister}`
Contribute a system-prompt fragment. text-or-fn is a string or a (ctx)->string function. opts may carry :id :title :description :order.
*tags:* prompt, extensions
_packages/core/src/fen/core/extensions/init.fnl:76_

### `fen.core.extensions.render-prompt`
`(render-prompt ctx) -> string`
Render all registered prompt fragments into one string, joined by blank lines, ordered by :order then registration order.
*tags:* prompt
_packages/core/src/fen/core/extensions/init.fnl:84_

### `fen.core.extensions.merged-tools`
`(merged-tools base) -> [Tool]`
Append registered :tool contributions to base, preserving order. Duplicates last-wins on tool name.
*tags:* tools
_packages/core/src/fen/core/extensions/init.fnl:91_

### `fen.core.extensions.run-before-tool`
`(run-before-tool tool-name args ctx) -> any`
Run all :before-tool hooks against the pending call. Hooks may inspect or replace args.
*tags:* hooks, tools
_packages/core/src/fen/core/extensions/init.fnl:98_

### `fen.core.extensions.unregister-by-owner`
`(unregister-by-owner owner) -> nil`
Drop every contribution and event handler tagged with owner. Used by the loader and by reloadable modules at the top of their bodies.
*tags:* extensions, reload
_packages/core/src/fen/core/extensions/init.fnl:106_

### `fen.core.extensions.list`
`(list kind) -> [record]`
List registered contributions of a given kind. kind is one of :tools :commands :controls :status :panels :presenters :providers :auth-backends :session-backends :extensions :event-handlers :prompt-fragments.
*tags:* extensions, introspection
_packages/core/src/fen/core/extensions/init.fnl:113_

### `fen.core.extensions.active-presenter`
_packages/core/src/fen/core/extensions/init.fnl:120_

### `fen.core.extensions.init-active-presenter`
_packages/core/src/fen/core/extensions/init.fnl:121_

### `fen.core.extensions.shutdown-active-presenter`
_packages/core/src/fen/core/extensions/init.fnl:122_

### `fen.core.extensions.run-active-presenter`
_packages/core/src/fen/core/extensions/init.fnl:123_

### `fen.core.extensions.build-ui-slot`
_packages/core/src/fen/core/extensions/init.fnl:124_

### `fen.core.extensions.find-provider`
`(find-provider name) -> provider|nil`
Look up a provider by its registered :name.
*tags:* provider
_packages/core/src/fen/core/extensions/init.fnl:125_

### `fen.core.extensions.find-provider-by-api`
`(find-provider-by-api api) -> provider|nil`
Find the first provider whose :api matches. Many providers can share an :api family.
*tags:* provider
_packages/core/src/fen/core/extensions/init.fnl:132_

### `fen.core.extensions.list-providers-by-api`
`(list-providers-by-api api) -> [provider]`
All providers registered for the given :api family.
*tags:* provider
_packages/core/src/fen/core/extensions/init.fnl:139_

### `fen.core.extensions.find-auth-backend`
`(find-auth-backend name) -> auth-backend|nil`
Look up an auth backend by its registered :name.
*tags:* auth, provider
_packages/core/src/fen/core/extensions/init.fnl:146_

### `fen.core.extensions.find-session-backend`
`(find-session-backend name) -> backend|nil`
Look up a session backend by its registered :name.
*tags:* session
_packages/core/src/fen/core/extensions/init.fnl:153_

### `fen.core.extensions.set-active-session-backend!`
`(set-active-session-backend! name) -> nil`
Activate a registered session backend by name. Subsequent appends route through it.
*tags:* session
_packages/core/src/fen/core/extensions/init.fnl:160_

### `fen.core.extensions.active-session-backend`
`(active-session-backend) -> backend|nil`
Return the active session backend record, or nil if --no-session is in effect.
*tags:* session
_packages/core/src/fen/core/extensions/init.fnl:168_

### `fen.core.extensions.set-session-info!`
`(set-session-info! info) -> nil`
Cache the SessionInfo returned by a backend's :start! for later inspection.
*tags:* session
_packages/core/src/fen/core/extensions/init.fnl:175_

### `fen.core.extensions.session-info`
`(session-info) -> SessionInfo|nil`
Return the session info cached by the active backend.
*tags:* session
_packages/core/src/fen/core/extensions/init.fnl:182_

### `fen.core.extensions.complete-once`
_packages/core/src/fen/core/extensions/init.fnl:197_

### `fen.core.extensions.settings-api`
_packages/core/src/fen/core/extensions/init.fnl:208_

### `fen.core.extensions.models-api`
_packages/core/src/fen/core/extensions/init.fnl:216_

### `fen.core.extensions.agent-info`
_packages/core/src/fen/core/extensions/init.fnl:225_

### `fen.core.extensions.types-api`
_packages/core/src/fen/core/extensions/init.fnl:233_

### `fen.core.extensions.record-extension!`
_packages/core/src/fen/core/extensions/init.fnl:236_

### `fen.core.extensions.reset!`
`(reset!) -> nil`
Wipe all registries in place so identity references (e.g. presenter ui-slot) survive reset.
*tags:* extensions, test, reload
_packages/core/src/fen/core/extensions/init.fnl:241_

### `fen.core.extensions.make-api`
`(make-api owner ?manifest) -> ExtensionApi`
Return the small stable api table handed to an extension. Carries owner-scoped wrappers around register / on / emit / prompt / list, plus the version field and a presenter ui-slot. This is the public extension contract.
*tags:* extensions, api, reload
_packages/core/src/fen/core/extensions/init.fnl:273_

## fen.core.extensions.events

### `fen.core.extensions.events.emit`
_packages/core/src/fen/core/extensions/events.fnl:55_

### `fen.core.extensions.events.on`
_packages/core/src/fen/core/extensions/events.fnl:62_

### `fen.core.extensions.events.unregister-by-owner`
_packages/core/src/fen/core/extensions/events.fnl:68_

### `fen.core.extensions.events.list`
_packages/core/src/fen/core/extensions/events.fnl:72_

## fen.core.extensions.loader

### `fen.core.extensions.loader.load-sibling`
_packages/core/src/fen/core/extensions/loader/init.fnl:205_

### `fen.core.extensions.loader.load!`
_packages/core/src/fen/core/extensions/loader/init.fnl:221_

### `fen.core.extensions.loader.summarize`
_packages/core/src/fen/core/extensions/loader/init.fnl:243_

### `fen.core.extensions.loader.reload-extension!`
_packages/core/src/fen/core/extensions/loader/init.fnl:255_

## fen.core.extensions.loader.discover

### `fen.core.extensions.loader.discover.first-party-roots`
_packages/core/src/fen/core/extensions/loader/discover.fnl:117_

### `fen.core.extensions.loader.discover.project-roots`
_packages/core/src/fen/core/extensions/loader/discover.fnl:149_

### `fen.core.extensions.loader.discover.user-roots`
_packages/core/src/fen/core/extensions/loader/discover.fnl:169_

### `fen.core.extensions.loader.discover.discover`
_packages/core/src/fen/core/extensions/loader/discover.fnl:299_

## fen.core.extensions.loader.reload

### `fen.core.extensions.loader.reload.file-changed?!`
_packages/core/src/fen/core/extensions/loader/reload.fnl:42_

### `fen.core.extensions.loader.reload.change-summary`
_packages/core/src/fen/core/extensions/loader/reload.fnl:46_

### `fen.core.extensions.loader.reload.clear-reload-modules!`
_packages/core/src/fen/core/extensions/loader/reload.fnl:73_

## fen.core.extensions.register

### `fen.core.extensions.register.register`
_packages/core/src/fen/core/extensions/register/init.fnl:38_

### `fen.core.extensions.register.unregister-by-owner`
_packages/core/src/fen/core/extensions/register/init.fnl:52_

### `fen.core.extensions.register.list`
_packages/core/src/fen/core/extensions/register/init.fnl:96_

### `fen.core.extensions.register.merged-tools`
_packages/core/src/fen/core/extensions/register/init.fnl:114_

### `fen.core.extensions.register.run-before-tool`
_packages/core/src/fen/core/extensions/register/init.fnl:115_

### `fen.core.extensions.register.dispatch-command`
_packages/core/src/fen/core/extensions/register/init.fnl:117_

### `fen.core.extensions.register.contribute`
_packages/core/src/fen/core/extensions/register/init.fnl:119_

### `fen.core.extensions.register.render-prompt`
_packages/core/src/fen/core/extensions/register/init.fnl:121_

### `fen.core.extensions.register.active-presenter`
_packages/core/src/fen/core/extensions/register/init.fnl:123_

### `fen.core.extensions.register.init-active-presenter`
_packages/core/src/fen/core/extensions/register/init.fnl:124_

### `fen.core.extensions.register.shutdown-active-presenter`
_packages/core/src/fen/core/extensions/register/init.fnl:125_

### `fen.core.extensions.register.run-active-presenter`
_packages/core/src/fen/core/extensions/register/init.fnl:126_

### `fen.core.extensions.register.build-ui-slot`
_packages/core/src/fen/core/extensions/register/init.fnl:127_

### `fen.core.extensions.register.find-provider`
_packages/core/src/fen/core/extensions/register/init.fnl:129_

### `fen.core.extensions.register.find-provider-by-api`
_packages/core/src/fen/core/extensions/register/init.fnl:130_

### `fen.core.extensions.register.list-providers-by-api`
_packages/core/src/fen/core/extensions/register/init.fnl:131_

### `fen.core.extensions.register.find-auth-backend`
_packages/core/src/fen/core/extensions/register/init.fnl:132_

### `fen.core.extensions.register.find-session-backend`
_packages/core/src/fen/core/extensions/register/init.fnl:133_

### `fen.core.extensions.register.set-active-session-backend!`
_packages/core/src/fen/core/extensions/register/init.fnl:134_

### `fen.core.extensions.register.active-session-backend`
_packages/core/src/fen/core/extensions/register/init.fnl:135_

### `fen.core.extensions.register.set-session-info!`
_packages/core/src/fen/core/extensions/register/init.fnl:136_

### `fen.core.extensions.register.session-info`
_packages/core/src/fen/core/extensions/register/init.fnl:137_

## fen.core.extensions.register.auth_backend

### `fen.core.extensions.register.auth_backend.register`
_packages/core/src/fen/core/extensions/register/auth_backend.fnl:6_

### `fen.core.extensions.register.auth_backend.unregister-by-owner`
_packages/core/src/fen/core/extensions/register/auth_backend.fnl:12_

### `fen.core.extensions.register.auth_backend.find`
_packages/core/src/fen/core/extensions/register/auth_backend.fnl:17_

### `fen.core.extensions.register.auth_backend.list`
_packages/core/src/fen/core/extensions/register/auth_backend.fnl:20_

## fen.core.extensions.register.command

### `fen.core.extensions.register.command.register`
_packages/core/src/fen/core/extensions/register/command.fnl:7_

### `fen.core.extensions.register.command.unregister-by-owner`
_packages/core/src/fen/core/extensions/register/command.fnl:16_

### `fen.core.extensions.register.command.dispatch`
_packages/core/src/fen/core/extensions/register/command.fnl:32_

### `fen.core.extensions.register.command.list`
_packages/core/src/fen/core/extensions/register/command.fnl:50_

## fen.core.extensions.register.control

### `fen.core.extensions.register.control.register`
_packages/core/src/fen/core/extensions/register/control.fnl:6_

### `fen.core.extensions.register.control.unregister-by-owner`
_packages/core/src/fen/core/extensions/register/control.fnl:12_

### `fen.core.extensions.register.control.list`
_packages/core/src/fen/core/extensions/register/control.fnl:16_

## fen.core.extensions.register.hook

### `fen.core.extensions.register.hook.register`
_packages/core/src/fen/core/extensions/register/hook.fnl:6_

### `fen.core.extensions.register.hook.unregister-by-owner`
_packages/core/src/fen/core/extensions/register/hook.fnl:14_

### `fen.core.extensions.register.hook.run-before-tool`
_packages/core/src/fen/core/extensions/register/hook.fnl:18_

## fen.core.extensions.register.panel

### `fen.core.extensions.register.panel.register`
_packages/core/src/fen/core/extensions/register/panel.fnl:27_

### `fen.core.extensions.register.panel.unregister-by-owner`
_packages/core/src/fen/core/extensions/register/panel.fnl:42_

### `fen.core.extensions.register.panel.list`
_packages/core/src/fen/core/extensions/register/panel.fnl:54_

## fen.core.extensions.register.presenter

### `fen.core.extensions.register.presenter.promote-ui-slot!`
_packages/core/src/fen/core/extensions/register/presenter.fnl:10_

### `fen.core.extensions.register.presenter.active-presenter`
_packages/core/src/fen/core/extensions/register/presenter.fnl:17_

### `fen.core.extensions.register.presenter.register`
_packages/core/src/fen/core/extensions/register/presenter.fnl:25_

### `fen.core.extensions.register.presenter.unregister-by-owner`
_packages/core/src/fen/core/extensions/register/presenter.fnl:37_

### `fen.core.extensions.register.presenter.init-active-presenter`
_packages/core/src/fen/core/extensions/register/presenter.fnl:55_

### `fen.core.extensions.register.presenter.shutdown-active-presenter`
_packages/core/src/fen/core/extensions/register/presenter.fnl:58_

### `fen.core.extensions.register.presenter.run-active-presenter`
_packages/core/src/fen/core/extensions/register/presenter.fnl:61_

### `fen.core.extensions.register.presenter.build-ui-slot`
_packages/core/src/fen/core/extensions/register/presenter.fnl:89_

### `fen.core.extensions.register.presenter.list`
_packages/core/src/fen/core/extensions/register/presenter.fnl:95_

## fen.core.extensions.register.prompt

### `fen.core.extensions.register.prompt.contribute`
_packages/core/src/fen/core/extensions/register/prompt.fnl:16_

### `fen.core.extensions.register.prompt.register`
_packages/core/src/fen/core/extensions/register/prompt.fnl:30_

### `fen.core.extensions.register.prompt.unregister-by-owner`
_packages/core/src/fen/core/extensions/register/prompt.fnl:34_

### `fen.core.extensions.register.prompt.render`
_packages/core/src/fen/core/extensions/register/prompt.fnl:62_

### `fen.core.extensions.register.prompt.list`
_packages/core/src/fen/core/extensions/register/prompt.fnl:83_

## fen.core.extensions.register.provider

### `fen.core.extensions.register.provider.register`
_packages/core/src/fen/core/extensions/register/provider.fnl:6_

### `fen.core.extensions.register.provider.unregister-by-owner`
_packages/core/src/fen/core/extensions/register/provider.fnl:17_

### `fen.core.extensions.register.provider.find`
_packages/core/src/fen/core/extensions/register/provider.fnl:22_

### `fen.core.extensions.register.provider.list-by-api`
_packages/core/src/fen/core/extensions/register/provider.fnl:27_

### `fen.core.extensions.register.provider.find-by-api`
_packages/core/src/fen/core/extensions/register/provider.fnl:37_

### `fen.core.extensions.register.provider.list`
_packages/core/src/fen/core/extensions/register/provider.fnl:43_

## fen.core.extensions.register.session_backend

### `fen.core.extensions.register.session_backend.register`
_packages/core/src/fen/core/extensions/register/session_backend.fnl:8_

### `fen.core.extensions.register.session_backend.unregister-by-owner`
_packages/core/src/fen/core/extensions/register/session_backend.fnl:18_

### `fen.core.extensions.register.session_backend.find`
_packages/core/src/fen/core/extensions/register/session_backend.fnl:26_

### `fen.core.extensions.register.session_backend.set-active!`
_packages/core/src/fen/core/extensions/register/session_backend.fnl:29_

### `fen.core.extensions.register.session_backend.active`
_packages/core/src/fen/core/extensions/register/session_backend.fnl:34_

### `fen.core.extensions.register.session_backend.set-info!`
_packages/core/src/fen/core/extensions/register/session_backend.fnl:38_

### `fen.core.extensions.register.session_backend.info`
_packages/core/src/fen/core/extensions/register/session_backend.fnl:42_

### `fen.core.extensions.register.session_backend.list`
_packages/core/src/fen/core/extensions/register/session_backend.fnl:44_

## fen.core.extensions.register.status

### `fen.core.extensions.register.status.register`
_packages/core/src/fen/core/extensions/register/status.fnl:12_

### `fen.core.extensions.register.status.unregister-by-owner`
_packages/core/src/fen/core/extensions/register/status.fnl:25_

### `fen.core.extensions.register.status.list`
_packages/core/src/fen/core/extensions/register/status.fnl:37_

## fen.core.extensions.register.tool

### `fen.core.extensions.register.tool.register`
_packages/core/src/fen/core/extensions/register/tool.fnl:6_

### `fen.core.extensions.register.tool.unregister-by-owner`
_packages/core/src/fen/core/extensions/register/tool.fnl:12_

### `fen.core.extensions.register.tool.merged`
_packages/core/src/fen/core/extensions/register/tool.fnl:16_

### `fen.core.extensions.register.tool.list`
_packages/core/src/fen/core/extensions/register/tool.fnl:23_

## fen.core.extensions.rocks

### `fen.core.extensions.rocks.default-tree`
_packages/core/src/fen/core/extensions/rocks.fnl:12_

### `fen.core.extensions.rocks.lua-path-fragment`
_packages/core/src/fen/core/extensions/rocks.fnl:18_

### `fen.core.extensions.rocks.lua-cpath-fragment`
_packages/core/src/fen/core/extensions/rocks.fnl:22_

### `fen.core.extensions.rocks.prepend-tree!`
_packages/core/src/fen/core/extensions/rocks.fnl:30_

### `fen.core.extensions.rocks.rockspecs`
_packages/core/src/fen/core/extensions/rocks.fnl:47_

### `fen.core.extensions.rocks.rockspec-present?`
_packages/core/src/fen/core/extensions/rocks.fnl:52_

### `fen.core.extensions.rocks.single-rockspec`
_packages/core/src/fen/core/extensions/rocks.fnl:55_

### `fen.core.extensions.rocks.parse-missing-module`
_packages/core/src/fen/core/extensions/rocks.fnl:64_

### `fen.core.extensions.rocks.manual-install-command`
_packages/core/src/fen/core/extensions/rocks.fnl:70_

### `fen.core.extensions.rocks.build-command`
_packages/core/src/fen/core/extensions/rocks.fnl:74_

### `fen.core.extensions.rocks.missing-module-message`
_packages/core/src/fen/core/extensions/rocks.fnl:86_

### `fen.core.extensions.rocks.missing-modules-message`
_packages/core/src/fen/core/extensions/rocks.fnl:96_

### `fen.core.extensions.rocks.build!`
_packages/core/src/fen/core/extensions/rocks.fnl:147_

## fen.core.extensions.state

### `fen.core.extensions.state.version`
_packages/core/src/fen/core/extensions/state.fnl:3_

### `fen.core.extensions.state.handlers`
_packages/core/src/fen/core/extensions/state.fnl:3_

### `fen.core.extensions.state.tools-extra`
_packages/core/src/fen/core/extensions/state.fnl:3_

### `fen.core.extensions.state.commands-extra`
_packages/core/src/fen/core/extensions/state.fnl:3_

### `fen.core.extensions.state.controls-extra`
_packages/core/src/fen/core/extensions/state.fnl:3_

### `fen.core.extensions.state.status-extra`
_packages/core/src/fen/core/extensions/state.fnl:3_

### `fen.core.extensions.state.panel-extra`
_packages/core/src/fen/core/extensions/state.fnl:3_

### `fen.core.extensions.state.presenters`
_packages/core/src/fen/core/extensions/state.fnl:3_

### `fen.core.extensions.state.providers`
_packages/core/src/fen/core/extensions/state.fnl:3_

### `fen.core.extensions.state.auth-backends`
_packages/core/src/fen/core/extensions/state.fnl:3_

### `fen.core.extensions.state.session-backends`
_packages/core/src/fen/core/extensions/state.fnl:3_

### `fen.core.extensions.state.session`
_packages/core/src/fen/core/extensions/state.fnl:3_

### `fen.core.extensions.state.hooks`
_packages/core/src/fen/core/extensions/state.fnl:3_

### `fen.core.extensions.state.prompt-fragments`
_packages/core/src/fen/core/extensions/state.fnl:3_

### `fen.core.extensions.state.prompt-next-seq`
_packages/core/src/fen/core/extensions/state.fnl:3_

### `fen.core.extensions.state.extensions`
_packages/core/src/fen/core/extensions/state.fnl:3_

### `fen.core.extensions.state.reload-fingerprints`
_packages/core/src/fen/core/extensions/state.fnl:3_

### `fen.core.extensions.state.ui`
_packages/core/src/fen/core/extensions/state.fnl:3_

## fen.core.extensions.test_api

### `fen.core.extensions.test_api.make`
_packages/core/src/fen/core/extensions/test_api.fnl:32_

## fen.core.extensions.util

### `fen.core.extensions.util.deep-copy`
_packages/core/src/fen/core/extensions/util.fnl:3_

### `fen.core.extensions.util.freeze`
_packages/core/src/fen/core/extensions/util.fnl:11_

### `fen.core.extensions.util.remove-where`
_packages/core/src/fen/core/extensions/util.fnl:31_

### `fen.core.extensions.util.clear-table`
_packages/core/src/fen/core/extensions/util.fnl:37_

### `fen.core.extensions.util.add-tagged!`
_packages/core/src/fen/core/extensions/util.fnl:40_

### `fen.core.extensions.util.set-tagged!`
_packages/core/src/fen/core/extensions/util.fnl:51_

## fen.core.llm

### `fen.core.llm.register`
`(register provider) -> provider`
Compatibility helper for in-process callers/tests. Prefer (extensions.register :provider provider owner) in extensions.
*tags:* provider, llm
_packages/core/src/fen/core/llm/init.fnl:10_

### `fen.core.llm.get-provider`
`(get-provider provider-name) -> provider`
Resolve a provider by registered :name. Errors if the name is unknown.
*tags:* provider, llm
_packages/core/src/fen/core/llm/init.fnl:21_

### `fen.core.llm.complete`
`(complete provider-name model context options ?on-event ?yield-fn) -> AssistantMessage`
Dispatch a completion to the named provider. Returns a canonical AssistantMessage. The provider chooses native streaming, cooperative-yield streaming, or blocking based on which callbacks are present.
*tags:* provider, llm
_packages/core/src/fen/core/llm/init.fnl:66_

### `fen.core.llm.emit-block-events`
`(emit-block-events asst emit) -> nil`
Synthesize streaming block events from a complete AssistantMessage. Compatibility bridge for providers that do not implement :complete-stream natively.
*tags:* provider, llm, streaming
_packages/core/src/fen/core/llm/init.fnl:30_

## fen.core.llm.event_stream

### `fen.core.llm.event_stream.new-stream`
_packages/core/src/fen/core/llm/event_stream.fnl:50_

### `fen.core.llm.event_stream.terminal-event?`
_packages/core/src/fen/core/llm/event_stream.fnl:50_

### `fen.core.llm.event_stream.event-result`
_packages/core/src/fen/core/llm/event_stream.fnl:50_

## fen.core.llm.models

### `fen.core.llm.models.config-dir`
_packages/core/src/fen/core/llm/models.fnl:263_

### `fen.core.llm.models.config-path`
_packages/core/src/fen/core/llm/models.fnl:263_

### `fen.core.llm.models.load`
_packages/core/src/fen/core/llm/models.fnl:263_

### `fen.core.llm.models.get-provider`
_packages/core/src/fen/core/llm/models.fnl:263_

### `fen.core.llm.models.register-providers!`
_packages/core/src/fen/core/llm/models.fnl:263_

### `fen.core.llm.models.resolve-api-key`
_packages/core/src/fen/core/llm/models.fnl:263_

### `fen.core.llm.models.looks-like-env-var?`
_packages/core/src/fen/core/llm/models.fnl:263_

### `fen.core.llm.models.first-model-id`
_packages/core/src/fen/core/llm/models.fnl:263_

### `fen.core.llm.models.available-models`
_packages/core/src/fen/core/llm/models.fnl:263_

### `fen.core.llm.models.canonical-model-id`
_packages/core/src/fen/core/llm/models.fnl:263_

### `fen.core.llm.models.resolve-model-exact`
_packages/core/src/fen/core/llm/models.fnl:263_

### `fen.core.llm.models.resolve-model`
_packages/core/src/fen/core/llm/models.fnl:263_

## fen.core.llm.retry

### `fen.core.llm.retry.DEFAULT-MAX-ATTEMPTS`
_packages/core/src/fen/core/llm/retry.fnl:145_

### `fen.core.llm.retry.DEFAULT-BASE-DELAY-MS`
_packages/core/src/fen/core/llm/retry.fnl:145_

### `fen.core.llm.retry.DEFAULT-MAX-DELAY-MS`
_packages/core/src/fen/core/llm/retry.fnl:145_

### `fen.core.llm.retry.transient?`
_packages/core/src/fen/core/llm/retry.fnl:145_

### `fen.core.llm.retry.parse-retry-after`
_packages/core/src/fen/core/llm/retry.fnl:145_

### `fen.core.llm.retry.backoff-delay`
_packages/core/src/fen/core/llm/retry.fnl:145_

### `fen.core.llm.retry.with-retry`
_packages/core/src/fen/core/llm/retry.fnl:145_

## fen.core.prompt

### `fen.core.prompt.build-context`
_packages/core/src/fen/core/prompt.fnl:11_

### `fen.core.prompt.build`
_packages/core/src/fen/core/prompt.fnl:15_

## fen.core.settings

### `fen.core.settings.config-dir`
_packages/core/src/fen/core/settings.fnl:15_

### `fen.core.settings.config-path`
_packages/core/src/fen/core/settings.fnl:18_

### `fen.core.settings.load`
_packages/core/src/fen/core/settings.fnl:48_

### `fen.core.settings.save!`
_packages/core/src/fen/core/settings.fnl:70_

### `fen.core.settings.set-defaults!`
_packages/core/src/fen/core/settings.fnl:82_

## fen.core.tools

### `fen.core.tools.descriptors`
_packages/core/src/fen/core/tools.fnl:87_

### `fen.core.tools.execute-call`
_packages/core/src/fen/core/tools.fnl:87_

## fen.core.types

### `fen.core.types.now-ms`
`(now-ms) -> number`
Current epoch in milliseconds. Used as the :timestamp field on canonical messages.
*tags:* types, time
_packages/core/src/fen/core/types.fnl:101_

### `fen.core.types.text-block`
`(text-block s) -> TextContent`
Build a {:type :text :text s} block. The visible-text content kind.
*tags:* types, content-block
_packages/core/src/fen/core/types.fnl:108_

### `fen.core.types.thinking-block`
`(thinking-block {: thinking : thinking-signature : redacted}) -> ThinkingContent`
Build a {:type :thinking ...} block. Carries reasoning text plus the opaque echo signature required by Anthropic extended thinking and OpenAI Responses for multi-turn echo.
*tags:* types, content-block, thinking
_packages/core/src/fen/core/types.fnl:116_

### `fen.core.types.tool-call-block`
`(tool-call-block id name args) -> ToolCall`
Build a {:type :tool-call :id :name :arguments} block. Arguments is a parsed Lua table — providers JSON-decode wire arguments before calling this.
*tags:* types, content-block, tool-call
_packages/core/src/fen/core/types.fnl:128_

### `fen.core.types.user-message`
`(user-message content) -> UserMessage`
Build a {:role :user :content :timestamp} message. content is a string or [TextContent].
*tags:* types, message
_packages/core/src/fen/core/types.fnl:137_

### `fen.core.types.assistant-message`
`(assistant-message {: content : api : provider : model : usage : stop-reason : error-message}) -> AssistantMessage`
Build a canonical AssistantMessage. Content defaults to []; usage and stop-reason fall back to safe defaults; error-message is set only when provided.
*tags:* types, message, assistant
_packages/core/src/fen/core/types.fnl:148_

### `fen.core.types.tool-result-message`
`(tool-result-message {: tool-call-id : tool-name : content : details : is-error?}) -> ToolResultMessage`
Build a canonical ToolResultMessage. content is always an array; details is opaque presenter payload.
*tags:* types, message, tool-result
_packages/core/src/fen/core/types.fnl:166_

### `fen.core.types.assistant-error`
`(assistant-error api provider model error-message) -> AssistantMessage`
Build an AssistantMessage representing a transport/HTTP failure. Sets stop-reason :error and inserts a synthetic "[error] ..." text block.
*tags:* types, message, error
_packages/core/src/fen/core/types.fnl:182_

### `fen.core.types.assistant-text`
`(assistant-text msg) -> string`
Concatenate every TextContent block in msg.content. Returns "" if there are no text blocks.
*tags:* types, message, accessor
_packages/core/src/fen/core/types.fnl:195_

### `fen.core.types.assistant-tool-calls`
`(assistant-tool-calls msg) -> [ToolCall]`
Return every :tool-call block in msg.content, in source order.
*tags:* types, message, accessor, tool-call
_packages/core/src/fen/core/types.fnl:215_

### `fen.core.types.assistant-thinking`
`(assistant-thinking msg) -> [ThinkingContent]`
Return every :thinking block in msg.content, in source order.
*tags:* types, message, accessor, thinking
_packages/core/src/fen/core/types.fnl:222_

## fen.extensions.agent_state.tool

### `fen.extensions.agent_state.tool.execute`
_extensions/agent-state/tool.fnl:343_

### `fen.extensions.agent_state.tool.parse-query`
_extensions/agent-state/tool.fnl:343_

### `fen.extensions.agent_state.tool.eval-query`
_extensions/agent-state/tool.fnl:343_

### `fen.extensions.agent_state.tool.sanitized-state`
_extensions/agent-state/tool.fnl:343_

## fen.extensions.builtin_commands.commands.extension

### `fen.extensions.builtin_commands.commands.extension.register`
_extensions/builtin-commands/commands/extension.fnl:252_

## fen.extensions.builtin_commands.commands.help

### `fen.extensions.builtin_commands.commands.help.register`
_extensions/builtin-commands/commands/help.fnl:90_

## fen.extensions.builtin_commands.commands.model

### `fen.extensions.builtin_commands.commands.model.register`
_extensions/builtin-commands/commands/model.fnl:117_

## fen.extensions.builtin_commands.commands.prompt

### `fen.extensions.builtin_commands.commands.prompt.register`
_extensions/builtin-commands/commands/prompt.fnl:101_

## fen.extensions.builtin_commands.commands.queue

### `fen.extensions.builtin_commands.commands.queue.register`
_extensions/builtin-commands/commands/queue.fnl:143_

## fen.extensions.builtin_commands.commands.session

### `fen.extensions.builtin_commands.commands.session.register`
_extensions/builtin-commands/commands/session.fnl:244_

## fen.extensions.builtin_commands.commands.status

### `fen.extensions.builtin_commands.commands.status.register`
_extensions/builtin-commands/commands/status.fnl:140_

## fen.extensions.builtin_commands.state.extensions

### `fen.extensions.builtin_commands.state.extensions.visible?`
_extensions/builtin-commands/state/extensions.fnl:3_

### `fen.extensions.builtin_commands.state.extensions.selected-name`
_extensions/builtin-commands/state/extensions.fnl:3_

### `fen.extensions.builtin_commands.state.extensions.cached-rows`
_extensions/builtin-commands/state/extensions.fnl:3_

### `fen.extensions.builtin_commands.state.extensions.cached-at`
_extensions/builtin-commands/state/extensions.fnl:3_

### `fen.extensions.builtin_commands.state.extensions.cached-w`
_extensions/builtin-commands/state/extensions.fnl:3_

### `fen.extensions.builtin_commands.state.extensions.cached-selected-name`
_extensions/builtin-commands/state/extensions.fnl:3_

## fen.extensions.builtin_commands.state.prompt

### `fen.extensions.builtin_commands.state.prompt.visible?`
_extensions/builtin-commands/state/prompt.fnl:3_

### `fen.extensions.builtin_commands.state.prompt.cached-rows`
_extensions/builtin-commands/state/prompt.fnl:3_

### `fen.extensions.builtin_commands.state.prompt.cached-at`
_extensions/builtin-commands/state/prompt.fnl:3_

### `fen.extensions.builtin_commands.state.prompt.cached-w`
_extensions/builtin-commands/state/prompt.fnl:3_

## fen.extensions.builtin_commands.state.queue

### `fen.extensions.builtin_commands.state.queue.visible?`
_extensions/builtin-commands/state/queue.fnl:3_

### `fen.extensions.builtin_commands.state.queue.cached-rows`
_extensions/builtin-commands/state/queue.fnl:3_

### `fen.extensions.builtin_commands.state.queue.cached-at`
_extensions/builtin-commands/state/queue.fnl:3_

### `fen.extensions.builtin_commands.state.queue.cached-w`
_extensions/builtin-commands/state/queue.fnl:3_

## fen.extensions.builtin_commands.state.status

### `fen.extensions.builtin_commands.state.status.visible?`
_extensions/builtin-commands/state/status.fnl:3_

### `fen.extensions.builtin_commands.state.status.cached-rows`
_extensions/builtin-commands/state/status.fnl:3_

### `fen.extensions.builtin_commands.state.status.cached-at`
_extensions/builtin-commands/state/status.fnl:3_

### `fen.extensions.builtin_commands.state.status.cached-w`
_extensions/builtin-commands/state/status.fnl:3_

## fen.extensions.builtin_commands.util

### `fen.extensions.builtin_commands.util.approx-tokens`
_extensions/builtin-commands/util.fnl:7_

### `fen.extensions.builtin_commands.util.safe-json`
_extensions/builtin-commands/util.fnl:14_

### `fen.extensions.builtin_commands.util.content-tokens`
_extensions/builtin-commands/util.fnl:18_

### `fen.extensions.builtin_commands.util.estimated-context-tokens`
_extensions/builtin-commands/util.fnl:36_

### `fen.extensions.builtin_commands.util.usage-totals`
_extensions/builtin-commands/util.fnl:44_

### `fen.extensions.builtin_commands.util.fmt-tokens`
_extensions/builtin-commands/util.fnl:58_

### `fen.extensions.builtin_commands.util.format-token-summary`
_extensions/builtin-commands/util.fnl:66_

### `fen.extensions.builtin_commands.util.runtime-version`
_extensions/builtin-commands/util.fnl:74_

### `fen.extensions.builtin_commands.util.nth-arg`
_extensions/builtin-commands/util.fnl:80_

### `fen.extensions.builtin_commands.util.first-arg`
_extensions/builtin-commands/util.fnl:84_

## fen.extensions.builtin_tools.bash

### `fen.extensions.builtin_tools.bash.name`
_extensions/builtin-tools/bash.fnl:75_

### `fen.extensions.builtin_tools.bash.bash`
_extensions/builtin-tools/bash.fnl:75_

### `fen.extensions.builtin_tools.bash.label`
_extensions/builtin-tools/bash.fnl:75_

### `fen.extensions.builtin_tools.bash.snippet`
_extensions/builtin-tools/bash.fnl:75_

### `fen.extensions.builtin_tools.bash.description`
_extensions/builtin-tools/bash.fnl:75_

### `fen.extensions.builtin_tools.bash.parameters`
_extensions/builtin-tools/bash.fnl:75_

### `fen.extensions.builtin_tools.bash.execute`
_extensions/builtin-tools/bash.fnl:75_

## fen.extensions.builtin_tools.edit

### `fen.extensions.builtin_tools.edit.name`
_extensions/builtin-tools/edit.fnl:149_

### `fen.extensions.builtin_tools.edit.edit`
_extensions/builtin-tools/edit.fnl:149_

### `fen.extensions.builtin_tools.edit.label`
_extensions/builtin-tools/edit.fnl:149_

### `fen.extensions.builtin_tools.edit.snippet`
_extensions/builtin-tools/edit.fnl:149_

### `fen.extensions.builtin_tools.edit.description`
_extensions/builtin-tools/edit.fnl:149_

### `fen.extensions.builtin_tools.edit.parameters`
_extensions/builtin-tools/edit.fnl:149_

### `fen.extensions.builtin_tools.edit.execute`
_extensions/builtin-tools/edit.fnl:149_

## fen.extensions.builtin_tools.find

### `fen.extensions.builtin_tools.find.name`
_extensions/builtin-tools/find.fnl:19_

### `fen.extensions.builtin_tools.find.find`
_extensions/builtin-tools/find.fnl:19_

### `fen.extensions.builtin_tools.find.label`
_extensions/builtin-tools/find.fnl:19_

### `fen.extensions.builtin_tools.find.snippet`
_extensions/builtin-tools/find.fnl:19_

### `fen.extensions.builtin_tools.find.description`
_extensions/builtin-tools/find.fnl:19_

### `fen.extensions.builtin_tools.find.parameters`
_extensions/builtin-tools/find.fnl:19_

### `fen.extensions.builtin_tools.find.execute`
_extensions/builtin-tools/find.fnl:19_

## fen.extensions.builtin_tools.grep

### `fen.extensions.builtin_tools.grep.name`
_extensions/builtin-tools/grep.fnl:27_

### `fen.extensions.builtin_tools.grep.grep`
_extensions/builtin-tools/grep.fnl:27_

### `fen.extensions.builtin_tools.grep.label`
_extensions/builtin-tools/grep.fnl:27_

### `fen.extensions.builtin_tools.grep.snippet`
_extensions/builtin-tools/grep.fnl:27_

### `fen.extensions.builtin_tools.grep.description`
_extensions/builtin-tools/grep.fnl:27_

### `fen.extensions.builtin_tools.grep.parameters`
_extensions/builtin-tools/grep.fnl:27_

### `fen.extensions.builtin_tools.grep.execute`
_extensions/builtin-tools/grep.fnl:27_

## fen.extensions.builtin_tools.ls

### `fen.extensions.builtin_tools.ls.name`
_extensions/builtin-tools/ls.fnl:22_

### `fen.extensions.builtin_tools.ls.ls`
_extensions/builtin-tools/ls.fnl:22_

### `fen.extensions.builtin_tools.ls.label`
_extensions/builtin-tools/ls.fnl:22_

### `fen.extensions.builtin_tools.ls.snippet`
_extensions/builtin-tools/ls.fnl:22_

### `fen.extensions.builtin_tools.ls.description`
_extensions/builtin-tools/ls.fnl:22_

### `fen.extensions.builtin_tools.ls.parameters`
_extensions/builtin-tools/ls.fnl:22_

### `fen.extensions.builtin_tools.ls.execute`
_extensions/builtin-tools/ls.fnl:22_

## fen.extensions.builtin_tools.read

### `fen.extensions.builtin_tools.read.name`
_extensions/builtin-tools/read.fnl:51_

### `fen.extensions.builtin_tools.read.read`
_extensions/builtin-tools/read.fnl:51_

### `fen.extensions.builtin_tools.read.label`
_extensions/builtin-tools/read.fnl:51_

### `fen.extensions.builtin_tools.read.snippet`
_extensions/builtin-tools/read.fnl:51_

### `fen.extensions.builtin_tools.read.description`
_extensions/builtin-tools/read.fnl:51_

### `fen.extensions.builtin_tools.read.parameters`
_extensions/builtin-tools/read.fnl:51_

### `fen.extensions.builtin_tools.read.execute`
_extensions/builtin-tools/read.fnl:51_

## fen.extensions.builtin_tools.registry

### `fen.extensions.builtin_tools.registry.registry`
_extensions/builtin-tools/registry.fnl:11_

## fen.extensions.builtin_tools.truncate

### `fen.extensions.builtin_tools.truncate.DEFAULT-MAX-LINES`
_extensions/builtin-tools/truncate.fnl:115_

### `fen.extensions.builtin_tools.truncate.DEFAULT-MAX-BYTES`
_extensions/builtin-tools/truncate.fnl:115_

### `fen.extensions.builtin_tools.truncate.truncate-head`
_extensions/builtin-tools/truncate.fnl:115_

### `fen.extensions.builtin_tools.truncate.truncate-tail`
_extensions/builtin-tools/truncate.fnl:115_

## fen.extensions.builtin_tools.util

### `fen.extensions.builtin_tools.util.agent-result`
_extensions/builtin-tools/util.fnl:34_

### `fen.extensions.builtin_tools.util.ok`
_extensions/builtin-tools/util.fnl:34_

### `fen.extensions.builtin_tools.util.err`
_extensions/builtin-tools/util.fnl:34_

### `fen.extensions.builtin_tools.util.shellquote`
_extensions/builtin-tools/util.fnl:34_

### `fen.extensions.builtin_tools.util.int-arg`
_extensions/builtin-tools/util.fnl:34_

### `fen.extensions.builtin_tools.util.result-text`
_extensions/builtin-tools/util.fnl:34_

### `fen.extensions.builtin_tools.util.dir-exists?`
_extensions/builtin-tools/util.fnl:34_

## fen.extensions.builtin_tools.write

### `fen.extensions.builtin_tools.write.name`
_extensions/builtin-tools/write.fnl:17_

### `fen.extensions.builtin_tools.write.write`
_extensions/builtin-tools/write.fnl:17_

### `fen.extensions.builtin_tools.write.label`
_extensions/builtin-tools/write.fnl:17_

### `fen.extensions.builtin_tools.write.snippet`
_extensions/builtin-tools/write.fnl:17_

### `fen.extensions.builtin_tools.write.description`
_extensions/builtin-tools/write.fnl:17_

### `fen.extensions.builtin_tools.write.parameters`
_extensions/builtin-tools/write.fnl:17_

### `fen.extensions.builtin_tools.write.execute`
_extensions/builtin-tools/write.fnl:17_

## fen.extensions.default_prompt

### `fen.extensions.default_prompt.tool-list-section`
_extensions/default-prompt/init.fnl:31_

### `fen.extensions.default_prompt.guidelines-section`
_extensions/default-prompt/init.fnl:40_

### `fen.extensions.default_prompt.context-section`
_extensions/default-prompt/init.fnl:59_

### `fen.extensions.default_prompt.default-prompt`
_extensions/default-prompt/init.fnl:126_

### `fen.extensions.default_prompt.register!`
_extensions/default-prompt/init.fnl:127_

### `fen.extensions.default_prompt.current-loader`
_extensions/default-prompt/init.fnl:128_

## fen.extensions.default_prompt.resources

### `fen.extensions.default_prompt.resources.make`
_extensions/default-prompt/resources.fnl:73_

### `fen.extensions.default_prompt.resources.cwd`
_extensions/default-prompt/resources.fnl:82_

### `fen.extensions.default_prompt.resources.config-dir`
_extensions/default-prompt/resources.fnl:83_

### `fen.extensions.default_prompt.resources.load-project-context-files`
_extensions/default-prompt/resources.fnl:84_

### `fen.extensions.default_prompt.resources.load-system-file`
_extensions/default-prompt/resources.fnl:85_

### `fen.extensions.default_prompt.resources._ancestors-root-to-leaf`
_extensions/default-prompt/resources.fnl:86_

## fen.extensions.docs

### `fen.extensions.docs.register`
_extensions/docs/init.fnl:421_

## fen.extensions.docs.state

### `fen.extensions.docs.state.visible?`
_extensions/docs/state.fnl:3_

### `fen.extensions.docs.state.selected-topic`
_extensions/docs/state.fnl:3_

### `fen.extensions.docs.state.selected-name`
_extensions/docs/state.fnl:3_

### `fen.extensions.docs.state.cached-rows`
_extensions/docs/state.fnl:3_

### `fen.extensions.docs.state.cached-at`
_extensions/docs/state.fnl:3_

### `fen.extensions.docs.state.cached-w`
_extensions/docs/state.fnl:3_

### `fen.extensions.docs.state.cached-selected-topic`
_extensions/docs/state.fnl:3_

### `fen.extensions.docs.state.cached-selected-name`
_extensions/docs/state.fnl:3_

## fen.extensions.handoff

### `fen.extensions.handoff.register!`
_extensions/handoff/init.fnl:122_

## fen.extensions.mem

### `fen.extensions.mem.report-rows`
_extensions/mem/init.fnl:131_

### `fen.extensions.mem.panel-spec`
_extensions/mem/init.fnl:193_

### `fen.extensions.mem.register!`
_extensions/mem/init.fnl:265_

### `fen.extensions.mem._state`
_extensions/mem/init.fnl:266_

## fen.extensions.mem.state

### `fen.extensions.mem.state.samples`
_extensions/mem/state.fnl:3_

### `fen.extensions.mem.state.max-samples`
_extensions/mem/state.fnl:3_

### `fen.extensions.mem.state.peak-kb`
_extensions/mem/state.fnl:3_

### `fen.extensions.mem.state.visible?`
_extensions/mem/state.fnl:3_

### `fen.extensions.mem.state.run-state`
_extensions/mem/state.fnl:3_

### `fen.extensions.mem.state.cached-rows`
_extensions/mem/state.fnl:3_

### `fen.extensions.mem.state.cached-at`
_extensions/mem/state.fnl:3_

### `fen.extensions.mem.state.cached-w`
_extensions/mem/state.fnl:3_

## fen.extensions.print

### `fen.extensions.print.run`
_extensions/print/init.fnl:13_

## fen.extensions.provider_anthropic.anthropic_messages

### `fen.extensions.provider_anthropic.anthropic_messages.api`
_extensions/provider-anthropic/anthropic_messages.fnl:530_

### `fen.extensions.provider_anthropic.anthropic_messages.provider`
_extensions/provider-anthropic/anthropic_messages.fnl:530_

### `fen.extensions.provider_anthropic.anthropic_messages.default-base-url`
_extensions/provider-anthropic/anthropic_messages.fnl:530_

### `fen.extensions.provider_anthropic.anthropic_messages.default-version`
_extensions/provider-anthropic/anthropic_messages.fnl:530_

### `fen.extensions.provider_anthropic.anthropic_messages.convert-messages`
_extensions/provider-anthropic/anthropic_messages.fnl:530_

### `fen.extensions.provider_anthropic.anthropic_messages.convert-tools`
_extensions/provider-anthropic/anthropic_messages.fnl:530_

### `fen.extensions.provider_anthropic.anthropic_messages.map-stop-reason`
_extensions/provider-anthropic/anthropic_messages.fnl:530_

### `fen.extensions.provider_anthropic.anthropic_messages.parse-response`
_extensions/provider-anthropic/anthropic_messages.fnl:530_

### `fen.extensions.provider_anthropic.anthropic_messages.process-stream-event!`
_extensions/provider-anthropic/anthropic_messages.fnl:530_

### `fen.extensions.provider_anthropic.anthropic_messages.finalize-stream-state`
_extensions/provider-anthropic/anthropic_messages.fnl:530_

### `fen.extensions.provider_anthropic.anthropic_messages.build-body`
_extensions/provider-anthropic/anthropic_messages.fnl:530_

### `fen.extensions.provider_anthropic.anthropic_messages.complete`
_extensions/provider-anthropic/anthropic_messages.fnl:530_

## fen.extensions.provider_openai.openai_completions

### `fen.extensions.provider_openai.openai_completions.api`
_extensions/provider-openai/openai_completions.fnl:606_

### `fen.extensions.provider_openai.openai_completions.provider`
_extensions/provider-openai/openai_completions.fnl:606_

### `fen.extensions.provider_openai.openai_completions.default-base-url`
_extensions/provider-openai/openai_completions.fnl:606_

### `fen.extensions.provider_openai.openai_completions.build-url`
_extensions/provider-openai/openai_completions.fnl:606_

### `fen.extensions.provider_openai.openai_completions.convert-messages`
_extensions/provider-openai/openai_completions.fnl:606_

### `fen.extensions.provider_openai.openai_completions.convert-tools`
_extensions/provider-openai/openai_completions.fnl:606_

### `fen.extensions.provider_openai.openai_completions.map-stop-reason`
_extensions/provider-openai/openai_completions.fnl:606_

### `fen.extensions.provider_openai.openai_completions.parse-response`
_extensions/provider-openai/openai_completions.fnl:606_

### `fen.extensions.provider_openai.openai_completions.process-stream-chunk!`
_extensions/provider-openai/openai_completions.fnl:606_

### `fen.extensions.provider_openai.openai_completions.finalize-stream-state`
_extensions/provider-openai/openai_completions.fnl:606_

### `fen.extensions.provider_openai.openai_completions.build-body`
_extensions/provider-openai/openai_completions.fnl:606_

### `fen.extensions.provider_openai.openai_completions.complete`
_extensions/provider-openai/openai_completions.fnl:606_

## fen.extensions.provider_openai.openai_responses

### `fen.extensions.provider_openai.openai_responses.api`
_extensions/provider-openai/openai_responses.fnl:155_

### `fen.extensions.provider_openai.openai_responses.provider`
_extensions/provider-openai/openai_responses.fnl:155_

### `fen.extensions.provider_openai.openai_responses.default-base-url`
_extensions/provider-openai/openai_responses.fnl:155_

### `fen.extensions.provider_openai.openai_responses.build-url`
_extensions/provider-openai/openai_responses.fnl:155_

### `fen.extensions.provider_openai.openai_responses.build-body`
_extensions/provider-openai/openai_responses.fnl:155_

### `fen.extensions.provider_openai.openai_responses.build-request-opts`
_extensions/provider-openai/openai_responses.fnl:155_

### `fen.extensions.provider_openai.openai_responses.make-stream-pipeline`
_extensions/provider-openai/openai_responses.fnl:155_

### `fen.extensions.provider_openai.openai_responses.finalize-stream`
_extensions/provider-openai/openai_responses.fnl:155_

### `fen.extensions.provider_openai.openai_responses.complete`
_extensions/provider-openai/openai_responses.fnl:155_

## fen.extensions.provider_openai.openai_responses_shared

### `fen.extensions.provider_openai.openai_responses_shared.convert-messages`
_extensions/provider-openai/openai_responses_shared.fnl:442_

### `fen.extensions.provider_openai.openai_responses_shared.convert-tools`
_extensions/provider-openai/openai_responses_shared.fnl:442_

### `fen.extensions.provider_openai.openai_responses_shared.map-stop-reason`
_extensions/provider-openai/openai_responses_shared.fnl:442_

### `fen.extensions.provider_openai.openai_responses_shared.new-stream-state`
_extensions/provider-openai/openai_responses_shared.fnl:442_

### `fen.extensions.provider_openai.openai_responses_shared.process-event!`
_extensions/provider-openai/openai_responses_shared.fnl:442_

### `fen.extensions.provider_openai.openai_responses_shared.finalize-stream-state`
_extensions/provider-openai/openai_responses_shared.fnl:442_

### `fen.extensions.provider_openai.openai_responses_shared.finish-current-block!`
_extensions/provider-openai/openai_responses_shared.fnl:442_

### `fen.extensions.provider_openai.openai_responses_shared.clamp-reasoning-effort`
_extensions/provider-openai/openai_responses_shared.fnl:442_

### `fen.extensions.provider_openai.openai_responses_shared.split-compound-id`
_extensions/provider-openai/openai_responses_shared.fnl:442_

### `fen.extensions.provider_openai.openai_responses_shared.parse-streaming-json`
_extensions/provider-openai/openai_responses_shared.fnl:442_

## fen.extensions.provider_openai_codex.openai_codex_keychain

### `fen.extensions.provider_openai_codex.openai_codex_keychain.default-agent-dir`
_extensions/provider-openai-codex/openai_codex_keychain.fnl:143_

### `fen.extensions.provider_openai_codex.openai_codex_keychain.default-auth-path`
_extensions/provider-openai-codex/openai_codex_keychain.fnl:143_

### `fen.extensions.provider_openai_codex.openai_codex_keychain.candidate-read-auth-paths`
_extensions/provider-openai-codex/openai_codex_keychain.fnl:143_

### `fen.extensions.provider_openai_codex.openai_codex_keychain.load`
_extensions/provider-openai-codex/openai_codex_keychain.fnl:143_

### `fen.extensions.provider_openai_codex.openai_codex_keychain.get`
_extensions/provider-openai-codex/openai_codex_keychain.fnl:143_

### `fen.extensions.provider_openai_codex.openai_codex_keychain.save`
_extensions/provider-openai-codex/openai_codex_keychain.fnl:143_

### `fen.extensions.provider_openai_codex.openai_codex_keychain.set`
_extensions/provider-openai-codex/openai_codex_keychain.fnl:143_

## fen.extensions.provider_openai_codex.openai_codex_login

### `fen.extensions.provider_openai_codex.openai_codex_login.AUTHORIZE-URL`
_extensions/provider-openai-codex/openai_codex_login.fnl:236_

### `fen.extensions.provider_openai_codex.openai_codex_login.REDIRECT-URI`
_extensions/provider-openai-codex/openai_codex_login.fnl:236_

### `fen.extensions.provider_openai_codex.openai_codex_login.SCOPE`
_extensions/provider-openai-codex/openai_codex_login.fnl:236_

### `fen.extensions.provider_openai_codex.openai_codex_login.ORIGINATOR`
_extensions/provider-openai-codex/openai_codex_login.fnl:236_

### `fen.extensions.provider_openai_codex.openai_codex_login.generate-pkce`
_extensions/provider-openai-codex/openai_codex_login.fnl:236_

### `fen.extensions.provider_openai_codex.openai_codex_login.build-authorize-url`
_extensions/provider-openai-codex/openai_codex_login.fnl:236_

### `fen.extensions.provider_openai_codex.openai_codex_login.parse-authorization-input`
_extensions/provider-openai-codex/openai_codex_login.fnl:236_

### `fen.extensions.provider_openai_codex.openai_codex_login.extract-query-param`
_extensions/provider-openai-codex/openai_codex_login.fnl:236_

### `fen.extensions.provider_openai_codex.openai_codex_login.exchange-code!`
_extensions/provider-openai-codex/openai_codex_login.fnl:236_

### `fen.extensions.provider_openai_codex.openai_codex_login.login!`
_extensions/provider-openai-codex/openai_codex_login.fnl:236_

### `fen.extensions.provider_openai_codex.openai_codex_login.logout!`
_extensions/provider-openai-codex/openai_codex_login.fnl:236_

## fen.extensions.provider_openai_codex.openai_codex_oauth

### `fen.extensions.provider_openai_codex.openai_codex_oauth.PROVIDER-ID`
_extensions/provider-openai-codex/openai_codex_oauth.fnl:153_

### `fen.extensions.provider_openai_codex.openai_codex_oauth.TOKEN-URL`
_extensions/provider-openai-codex/openai_codex_oauth.fnl:153_

### `fen.extensions.provider_openai_codex.openai_codex_oauth.CLIENT-ID`
_extensions/provider-openai-codex/openai_codex_oauth.fnl:153_

### `fen.extensions.provider_openai_codex.openai_codex_oauth.decode-jwt`
_extensions/provider-openai-codex/openai_codex_oauth.fnl:153_

### `fen.extensions.provider_openai_codex.openai_codex_oauth.extract-account-id`
_extensions/provider-openai-codex/openai_codex_oauth.fnl:153_

### `fen.extensions.provider_openai_codex.openai_codex_oauth.refresh!`
_extensions/provider-openai-codex/openai_codex_oauth.fnl:153_

### `fen.extensions.provider_openai_codex.openai_codex_oauth.expiring-soon?`
_extensions/provider-openai-codex/openai_codex_oauth.fnl:153_

### `fen.extensions.provider_openai_codex.openai_codex_oauth.configured?`
_extensions/provider-openai-codex/openai_codex_oauth.fnl:153_

### `fen.extensions.provider_openai_codex.openai_codex_oauth.get-fresh-creds!`
_extensions/provider-openai-codex/openai_codex_oauth.fnl:153_

### `fen.extensions.provider_openai_codex.openai_codex_oauth.form-encode`
_extensions/provider-openai-codex/openai_codex_oauth.fnl:153_

### `fen.extensions.provider_openai_codex.openai_codex_oauth.url-encode`
_extensions/provider-openai-codex/openai_codex_oauth.fnl:153_

## fen.extensions.provider_openai_codex.openai_codex_responses

### `fen.extensions.provider_openai_codex.openai_codex_responses.api`
_extensions/provider-openai-codex/openai_codex_responses.fnl:118_

### `fen.extensions.provider_openai_codex.openai_codex_responses.provider`
_extensions/provider-openai-codex/openai_codex_responses.fnl:118_

### `fen.extensions.provider_openai_codex.openai_codex_responses.default-base-url`
_extensions/provider-openai-codex/openai_codex_responses.fnl:118_

### `fen.extensions.provider_openai_codex.openai_codex_responses.build-url`
_extensions/provider-openai-codex/openai_codex_responses.fnl:118_

### `fen.extensions.provider_openai_codex.openai_codex_responses.map-codex-event`
_extensions/provider-openai-codex/openai_codex_responses.fnl:118_

### `fen.extensions.provider_openai_codex.openai_codex_responses.build-headers`
_extensions/provider-openai-codex/openai_codex_responses.fnl:118_

### `fen.extensions.provider_openai_codex.openai_codex_responses.merge-options`
_extensions/provider-openai-codex/openai_codex_responses.fnl:118_

### `fen.extensions.provider_openai_codex.openai_codex_responses.complete`
_extensions/provider-openai-codex/openai_codex_responses.fnl:118_

## fen.extensions.session_jsonl.session

### `fen.extensions.session_jsonl.session.open`
_extensions/session-jsonl/session.fnl:313_

### `fen.extensions.session_jsonl.session.open-existing`
_extensions/session-jsonl/session.fnl:313_

### `fen.extensions.session_jsonl.session.append`
_extensions/session-jsonl/session.fnl:313_

### `fen.extensions.session_jsonl.session.close`
_extensions/session-jsonl/session.fnl:313_

### `fen.extensions.session_jsonl.session.latest-for-cwd`
_extensions/session-jsonl/session.fnl:313_

### `fen.extensions.session_jsonl.session.list-for-cwd`
_extensions/session-jsonl/session.fnl:313_

### `fen.extensions.session_jsonl.session.header`
_extensions/session-jsonl/session.fnl:313_

### `fen.extensions.session_jsonl.session.title`
_extensions/session-jsonl/session.fnl:313_

### `fen.extensions.session_jsonl.session.message-count`
_extensions/session-jsonl/session.fnl:313_

### `fen.extensions.session_jsonl.session.find`
_extensions/session-jsonl/session.fnl:313_

### `fen.extensions.session_jsonl.session.load`
_extensions/session-jsonl/session.fnl:313_

### `fen.extensions.session_jsonl.session.sessions-root`
_extensions/session-jsonl/session.fnl:313_

### `fen.extensions.session_jsonl.session.cwd-slug`
_extensions/session-jsonl/session.fnl:313_

### `fen.extensions.session_jsonl.session.VERSION`
_extensions/session-jsonl/session.fnl:313_

## fen.extensions.skills

### `fen.extensions.skills.dir-exists?`
_extensions/skills/init.fnl:45_

### `fen.extensions.skills.file-exists?`
_extensions/skills/init.fnl:46_

### `fen.extensions.skills.realpath`
_extensions/skills/init.fnl:47_

### `fen.extensions.skills.parse-frontmatter`
_extensions/skills/init.fnl:101_

### `fen.extensions.skills.discover`
_extensions/skills/init.fnl:215_

### `fen.extensions.skills.system-prompt-section`
_extensions/skills/init.fnl:230_

### `fen.extensions.skills.user-skills-dir`
_extensions/skills/init.fnl:253_

### `fen.extensions.skills.project-skills-dir`
_extensions/skills/init.fnl:254_

### `fen.extensions.skills._discover-from-roots`
_extensions/skills/init.fnl:255_

### `fen.extensions.skills._default-roots`
_extensions/skills/init.fnl:256_

### `fen.extensions.skills._ancestors`
_extensions/skills/init.fnl:257_

### `fen.extensions.skills.register!`
_extensions/skills/init.fnl:283_

## fen.extensions.skills.ignore

### `fen.extensions.skills.ignore.with-dir`
_extensions/skills/ignore.fnl:76_

### `fen.extensions.skills.ignore.load-chain`
_extensions/skills/ignore.fnl:82_

### `fen.extensions.skills.ignore.match?`
_extensions/skills/ignore.fnl:142_

## fen.extensions.stdio

### `fen.extensions.stdio.render-event`
_extensions/stdio/init.fnl:115_

### `fen.extensions.stdio.stdin-tty?`
_extensions/stdio/init.fnl:149_

### `fen.extensions.stdio.drain-turn`
_extensions/stdio/init.fnl:159_

### `fen.extensions.stdio.submit-line`
_extensions/stdio/init.fnl:169_

### `fen.extensions.stdio.run`
_extensions/stdio/init.fnl:178_

### `fen.extensions.stdio.notify`
_extensions/stdio/init.fnl:192_

### `fen.extensions.stdio.prompt`
_extensions/stdio/init.fnl:195_

### `fen.extensions.stdio.select`
_extensions/stdio/init.fnl:201_

## fen.extensions.tui

### `fen.extensions.tui.init!`
_extensions/tui/init.fnl:46_

### `fen.extensions.tui.shutdown`
_extensions/tui/init.fnl:86_

### `fen.extensions.tui.reset-conversation!`
_extensions/tui/init.fnl:94_

### `fen.extensions.tui.set-status-info`
_extensions/tui/init.fnl:134_

### `fen.extensions.tui.peek-timeout-ms`
_extensions/tui/init.fnl:148_

### `fen.extensions.tui.run`
_extensions/tui/init.fnl:160_

## fen.extensions.tui.draw

### `fen.extensions.tui.draw.in-bounds?`
_extensions/tui/draw.fnl:14_

### `fen.extensions.tui.draw.fill-row`
_extensions/tui/draw.fnl:18_

### `fen.extensions.tui.draw.utf8-prefix-cols`
_extensions/tui/draw.fnl:29_

### `fen.extensions.tui.draw.put-clipped`
_extensions/tui/draw.fnl:59_

## fen.extensions.tui.ingest

### `fen.extensions.tui.ingest.append-event`
_extensions/tui/ingest.fnl:83_

## fen.extensions.tui.input

### `fen.extensions.tui.input.ensure-defaults!`
_extensions/tui/input.fnl:37_

### `fen.extensions.tui.input.input-display-rows`
_extensions/tui/input.fnl:53_

### `fen.extensions.tui.input.cursor-display-pos`
_extensions/tui/input.fnl:105_

### `fen.extensions.tui.input.input-rows`
_extensions/tui/input.fnl:115_

### `fen.extensions.tui.input.paint-input`
_extensions/tui/input.fnl:123_

### `fen.extensions.tui.input.handle-key`
_extensions/tui/input.fnl:411_

### `fen.extensions.tui.input.handle-mouse`
_extensions/tui/input.fnl:565_

### `fen.extensions.tui.input.handle-event`
_extensions/tui/input.fnl:577_

## fen.extensions.tui.markdown

### `fen.extensions.tui.markdown.parse`
_extensions/tui/markdown.fnl:575_

### `fen.extensions.tui.markdown.parse-inline`
_extensions/tui/markdown.fnl:576_

### `fen.extensions.tui.markdown.render-block`
_extensions/tui/markdown.fnl:577_

### `fen.extensions.tui.markdown.render-text`
_extensions/tui/markdown.fnl:578_

### `fen.extensions.tui.markdown.render`
_extensions/tui/markdown.fnl:579_

### `fen.extensions.tui.markdown.display-len`
_extensions/tui/markdown.fnl:580_

## fen.extensions.tui.paint

### `fen.extensions.tui.paint.ensure-state-defaults!`
_extensions/tui/paint.fnl:47_

### `fen.extensions.tui.paint.max-scroll`
_extensions/tui/paint.fnl:62_

### `fen.extensions.tui.paint.input-display-rows`
_extensions/tui/paint.fnl:72_

### `fen.extensions.tui.paint.cursor-display-pos`
_extensions/tui/paint.fnl:76_

### `fen.extensions.tui.paint.input-rows`
_extensions/tui/paint.fnl:80_

### `fen.extensions.tui.paint.layout`
_extensions/tui/paint.fnl:140_

### `fen.extensions.tui.paint.fmt-tokens`
_extensions/tui/paint.fnl:186_

### `fen.extensions.tui.paint.paint-status`
_extensions/tui/paint.fnl:190_

### `fen.extensions.tui.paint.paint-panels`
_extensions/tui/paint.fnl:246_

### `fen.extensions.tui.paint.paint-transcript`
_extensions/tui/paint.fnl:257_

### `fen.extensions.tui.paint.paint-input`
_extensions/tui/paint.fnl:269_

### `fen.extensions.tui.paint.invalidate!`
_extensions/tui/paint.fnl:275_

### `fen.extensions.tui.paint.invalidate-full!`
_extensions/tui/paint.fnl:280_

### `fen.extensions.tui.paint.busy?`
_extensions/tui/paint.fnl:287_

### `fen.extensions.tui.paint.advance-spinner-if-due!`
_extensions/tui/paint.fnl:291_

### `fen.extensions.tui.paint.redraw-if-needed!`
_extensions/tui/paint.fnl:305_

### `fen.extensions.tui.paint.paint-frame!`
_extensions/tui/paint.fnl:321_

### `fen.extensions.tui.paint.redraw!`
_extensions/tui/paint.fnl:338_

### `fen.extensions.tui.paint.clear-render-caches!`
_extensions/tui/paint.fnl:343_

### `fen.extensions.tui.paint.force-redraw!`
_extensions/tui/paint.fnl:349_

## fen.extensions.tui.panels.busy

### `fen.extensions.tui.panels.busy.spin-char`
_extensions/tui/panels/busy.fnl:15_

### `fen.extensions.tui.panels.busy.turn-elapsed`
_extensions/tui/panels/busy.fnl:23_

### `fen.extensions.tui.panels.busy.height`
_extensions/tui/panels/busy.fnl:48_

### `fen.extensions.tui.panels.busy.render`
_extensions/tui/panels/busy.fnl:51_

### `fen.extensions.tui.panels.busy.spec`
_extensions/tui/panels/busy.fnl:59_

## fen.extensions.tui.panels.status

### `fen.extensions.tui.panels.status.ensure-defaults!`
_extensions/tui/panels/status.fnl:29_

### `fen.extensions.tui.panels.status.paint`
_extensions/tui/panels/status.fnl:92_

## fen.extensions.tui.panels.transcript

### `fen.extensions.tui.panels.transcript.TOOL-RESULT-PREVIEW-BYTES`
_extensions/tui/panels/transcript.fnl:18_

### `fen.extensions.tui.panels.transcript.ensure-defaults!`
_extensions/tui/panels/transcript.fnl:20_

### `fen.extensions.tui.panels.transcript.args-`
_extensions/tui/panels/transcript.fnl:44_

### `fen.extensions.tui.panels.transcript.content-`
_extensions/tui/panels/transcript.fnl:50_

### `fen.extensions.tui.panels.transcript.truncate`
_extensions/tui/panels/transcript.fnl:59_

### `fen.extensions.tui.panels.transcript.count-lines`
_extensions/tui/panels/transcript.fnl:63_

### `fen.extensions.tui.panels.transcript.lookup-tool-call`
_extensions/tui/panels/transcript.fnl:90_

### `fen.extensions.tui.panels.transcript.split-lines`
_extensions/tui/panels/transcript.fnl:122_

### `fen.extensions.tui.panels.transcript.tool-call-short`
_extensions/tui/panels/transcript.fnl:175_

### `fen.extensions.tui.panels.transcript.event-text`
_extensions/tui/panels/transcript.fnl:201_

### `fen.extensions.tui.panels.transcript.invalidate-layout-cache!`
_extensions/tui/panels/transcript.fnl:346_

### `fen.extensions.tui.panels.transcript.clear-event-render-cache!`
_extensions/tui/panels/transcript.fnl:351_

### `fen.extensions.tui.panels.transcript.lines-for-event`
_extensions/tui/panels/transcript.fnl:374_

### `fen.extensions.tui.panels.transcript.viewport-lines`
_extensions/tui/panels/transcript.fnl:488_

### `fen.extensions.tui.panels.transcript.max-scroll`
_extensions/tui/panels/transcript.fnl:498_

### `fen.extensions.tui.panels.transcript.clear-render-caches!`
_extensions/tui/panels/transcript.fnl:507_

## fen.extensions.tui.select

### `fen.extensions.tui.select.filtered`
_extensions/tui/select.fnl:46_

### `fen.extensions.tui.select.make-state`
_extensions/tui/select.fnl:58_

### `fen.extensions.tui.select.step!`
_extensions/tui/select.fnl:68_

### `fen.extensions.tui.select.tui-select`
_extensions/tui/select.fnl:202_

## fen.extensions.tui.state

### `fen.extensions.tui.state.tb-initialized?`
_extensions/tui/state.fnl:10_

### `fen.extensions.tui.state.tb-init-failed?`
_extensions/tui/state.fnl:10_

### `fen.extensions.tui.state.tb-cols`
_extensions/tui/state.fnl:10_

### `fen.extensions.tui.state.tb-rows`
_extensions/tui/state.fnl:10_

### `fen.extensions.tui.state.dirty?`
_extensions/tui/state.fnl:10_

### `fen.extensions.tui.state.force-redraw?`
_extensions/tui/state.fnl:10_

### `fen.extensions.tui.state.spinner-ticks`
_extensions/tui/state.fnl:10_

### `fen.extensions.tui.state.spinner-interval-ticks`
_extensions/tui/state.fnl:10_

### `fen.extensions.tui.state.animations?`
_extensions/tui/state.fnl:10_

### `fen.extensions.tui.state.transcript`
_extensions/tui/state.fnl:10_

### `fen.extensions.tui.state.streaming-assistant-rows`
_extensions/tui/state.fnl:10_

### `fen.extensions.tui.state.transcript-layout-cache`
_extensions/tui/state.fnl:10_

### `fen.extensions.tui.state.scroll-offset`
_extensions/tui/state.fnl:10_

### `fen.extensions.tui.state.input-buf`
_extensions/tui/state.fnl:10_

### `fen.extensions.tui.state.input-cursor`
_extensions/tui/state.fnl:10_

### `fen.extensions.tui.state.paste-active?`
_extensions/tui/state.fnl:10_

### `fen.extensions.tui.state.paste-buffer`
_extensions/tui/state.fnl:10_

### `fen.extensions.tui.state.paste-counter`
_extensions/tui/state.fnl:10_

### `fen.extensions.tui.state.pastes`
_extensions/tui/state.fnl:10_

### `fen.extensions.tui.state.history`
_extensions/tui/state.fnl:10_

### `fen.extensions.tui.state.history-pos`
_extensions/tui/state.fnl:10_

### `fen.extensions.tui.state.history-draft`
_extensions/tui/state.fnl:10_

### `fen.extensions.tui.state.expand-tool-results?`
_extensions/tui/state.fnl:10_

### `fen.extensions.tui.state.markdown?`
_extensions/tui/state.fnl:10_

### `fen.extensions.tui.state.hide-thinking-block?`
_extensions/tui/state.fnl:10_

### `fen.extensions.tui.state.pending-quit?`
_extensions/tui/state.fnl:10_

### `fen.extensions.tui.state.alt-pending?`
_extensions/tui/state.fnl:10_

### `fen.extensions.tui.state.on-tick`
_extensions/tui/state.fnl:10_

### `fen.extensions.tui.state.cancel-pressed?`
_extensions/tui/state.fnl:10_

### `fen.extensions.tui.state.status-info`
_extensions/tui/state.fnl:10_

## fen.extensions.web

### `fen.extensions.web.init!`
_extensions/web/init.fnl:74_

### `fen.extensions.web.shutdown`
_extensions/web/init.fnl:77_

### `fen.extensions.web.run`
_extensions/web/init.fnl:80_

## fen.extensions.web.ingest

### `fen.extensions.web.ingest.append-event`
_extensions/web/ingest.fnl:79_

## fen.extensions.web.layout

### `fen.extensions.web.layout.snapshot`
_extensions/web/layout.fnl:116_

### `fen.extensions.web.layout.html-snapshot`
_extensions/web/layout.fnl:182_

## fen.extensions.web.page

### `fen.extensions.web.page.render`
_extensions/web/page.fnl:66_

### `fen.extensions.web.page.render-node`
_extensions/web/page.fnl:67_

### `fen.extensions.web.page.html`
_extensions/web/page.fnl:222_

## fen.extensions.web.server

### `fen.extensions.web.server.parse-request`
_extensions/web/server.fnl:68_

### `fen.extensions.web.server.broadcast!`
_extensions/web/server.fnl:242_

### `fen.extensions.web.server.init`
_extensions/web/server.fnl:245_

### `fen.extensions.web.server.shutdown`
_extensions/web/server.fnl:256_

### `fen.extensions.web.server.tick`
_extensions/web/server.fnl:267_

### `fen.extensions.web.server.wait-select`
_extensions/web/server.fnl:285_

### `fen.extensions.web.server.run`
_extensions/web/server.fnl:304_

## fen.extensions.web.state

### `fen.extensions.web.state.server`
_extensions/web/state.fnl:4_

### `fen.extensions.web.state.host`
_extensions/web/state.fnl:4_

### `fen.extensions.web.state.port`
_extensions/web/state.fnl:4_

### `fen.extensions.web.state.clients`
_extensions/web/state.fnl:4_

### `fen.extensions.web.state.sse-clients`
_extensions/web/state.fnl:4_

### `fen.extensions.web.state.pending-inputs`
_extensions/web/state.fnl:4_

### `fen.extensions.web.state.quit?`
_extensions/web/state.fnl:4_

### `fen.extensions.web.state.last-snapshot`
_extensions/web/state.fnl:4_

### `fen.extensions.web.state.last-broadcast`
_extensions/web/state.fnl:4_

### `fen.extensions.web.state.client-reload-seq`
_extensions/web/state.fnl:4_

### `fen.extensions.web.state.select-seq`
_extensions/web/state.fnl:4_

### `fen.extensions.web.state.active-select`
_extensions/web/state.fnl:4_

### `fen.extensions.web.state.presenter-ctx`
_extensions/web/state.fnl:4_

### `fen.extensions.web.state.transcript`
_extensions/web/state.fnl:4_

### `fen.extensions.web.state.status-info`
_extensions/web/state.fnl:4_

## fen.util.base64

### `fen.util.base64.decode-standard`
_packages/util/src/fen/util/base64.fnl:100_

### `fen.util.base64.decode-url`
_packages/util/src/fen/util/base64.fnl:100_

### `fen.util.base64.encode-standard`
_packages/util/src/fen/util/base64.fnl:100_

### `fen.util.base64.encode-url`
_packages/util/src/fen/util/base64.fnl:100_

## fen.util.checksum

### `fen.util.checksum.file-fingerprint`
_packages/util/src/fen/util/checksum.fnl:36_

### `fen.util.checksum.module-path`
_packages/util/src/fen/util/checksum.fnl:36_

### `fen.util.checksum.module-fingerprint`
_packages/util/src/fen/util/checksum.fnl:36_

## fen.util.flat_extensions

### `fen.util.flat_extensions.build-map`
_packages/util/src/fen/util/flat_extensions.fnl:64_

### `fen.util.flat_extensions.make-searcher`
_packages/util/src/fen/util/flat_extensions.fnl:96_

### `fen.util.flat_extensions.install!`
_packages/util/src/fen/util/flat_extensions.fnl:108_

## fen.util.http

### `fen.util.http.request`
_packages/util/src/fen/util/http/init.fnl:39_

## fen.util.http.backends.native

### `fen.util.http.backends.native.request`
_packages/util/src/fen/util/http/backends/native.fnl:31_

## fen.util.json

### `fen.util.json.encode`
_packages/util/src/fen/util/json.fnl:9_

### `fen.util.json.decode`
_packages/util/src/fen/util/json.fnl:9_

### `fen.util.json.null`
_packages/util/src/fen/util/json.fnl:9_

### `fen.util.json.empty-array`
_packages/util/src/fen/util/json.fnl:9_

## fen.util.log

### `fen.util.log.debug`
_packages/util/src/fen/util/log.fnl:11_

### `fen.util.log.info`
_packages/util/src/fen/util/log.fnl:11_

### `fen.util.log.warn`
_packages/util/src/fen/util/log.fnl:11_

### `fen.util.log.error`
_packages/util/src/fen/util/log.fnl:11_

## fen.util.path

### `fen.util.path.home`
_packages/util/src/fen/util/path.fnl:16_

### `fen.util.path.config-home`
_packages/util/src/fen/util/path.fnl:19_

### `fen.util.path.config-dir`
_packages/util/src/fen/util/path.fnl:25_

### `fen.util.path.state-home`
_packages/util/src/fen/util/path.fnl:28_

### `fen.util.path.state-dir`
_packages/util/src/fen/util/path.fnl:34_

### `fen.util.path.data-home`
_packages/util/src/fen/util/path.fnl:37_

### `fen.util.path.data-dir`
_packages/util/src/fen/util/path.fnl:43_

### `fen.util.path.shell-quote`
_packages/util/src/fen/util/path.fnl:46_

### `fen.util.path.dirname`
_packages/util/src/fen/util/path.fnl:49_

### `fen.util.path.basename`
_packages/util/src/fen/util/path.fnl:55_

### `fen.util.path.pwd-physical`
_packages/util/src/fen/util/path.fnl:58_

### `fen.util.path.cwd`
_packages/util/src/fen/util/path.fnl:66_

### `fen.util.path.realpath`
_packages/util/src/fen/util/path.fnl:69_

### `fen.util.path.file-exists?`
_packages/util/src/fen/util/path.fnl:83_

### `fen.util.path.dir-exists?`
_packages/util/src/fen/util/path.fnl:88_

### `fen.util.path.ancestors-root-to-leaf`
_packages/util/src/fen/util/path.fnl:91_

## fen.util.process

### `fen.util.process.read-pipe-coop`
_packages/util/src/fen/util/process.fnl:42_

## fen.util.random

### `fen.util.random.bytes`
_packages/util/src/fen/util/random.fnl:16_

## fen.util.sha256

### `fen.util.sha256.digest`
_packages/util/src/fen/util/sha256.fnl:120_

### `fen.util.sha256.hex-digest`
_packages/util/src/fen/util/sha256.fnl:120_

## fen.util.sse

### `fen.util.sse.new-parser`
_packages/util/src/fen/util/sse.fnl:110_

### `fen.util.sse.parse`
_packages/util/src/fen/util/sse.fnl:110_

### `fen.util.sse.json-events`
_packages/util/src/fen/util/sse.fnl:110_
