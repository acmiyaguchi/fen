# Providers and models

Provider-facing contracts, wire-shape differences, and custom model configuration.

## First-run setup help

Fen starts with the saved provider from `~/.config/fen/settings.json`, or `openai` when no setting exists.
If that provider is missing credentials, startup prints provider onboarding guidance instead of only naming the missing variable.
Use the provider setup pages for manpage-style help without starting the TUI:

```sh
fen providers
fen providers openai
fen providers openai-responses
fen providers anthropic
fen providers openai-codex
fen providers openrouter
fen providers sakana
fen providers ollama
```

The short path for built-ins is:

```sh
export OPENAI_API_KEY=sk-...          # openai or openai-responses
export ANTHROPIC_API_KEY=sk-ant-...  # anthropic
export OPENROUTER_API_KEY=sk-or-...   # openrouter (curated gateway models)
export SAKANA_API_KEY=...             # sakana (Fugu models)
fen --login openai-codex             # ChatGPT subscription / Codex OAuth
```

Local Ollama, vLLM, LM Studio, and proxies are configured through `~/.config/fen/models.json`; see [Custom providers](#custom-providers-modelsjson).

## Sakana AI

Sakana AI is a first-party provider that speaks the OpenAI Responses wire protocol against `https://api.sakana.ai/v1`.
It is authenticated by `SAKANA_API_KEY` and ships the Fugu reasoning models.

```sh
export SAKANA_API_KEY=...
fen --provider sakana --model fugu-ultra
```

Fen queries Sakana's authenticated `GET /models` catalog when listing or resolving models, and falls back to the shipped list when the catalog is unavailable.
The shipped fallback is `fugu-ultra` (default), `fugu`, and `fugu-ultra-20260615`.
All shipped Fugu models are reasoning-only models with a 1M-token context window.

Sakana accepts only the reasoning efforts `high` and `xhigh` (`max` is an alias of `xhigh`); any other value is rejected.
The provider maps fen's thinking levels accordingly: `off` sends no reasoning effort (Sakana uses its default), `minimal`/`low`/`medium`/`high` all send `high`, and `xhigh` sends `xhigh`.
Use `--thinking`/`/thinking` as usual; the clamp is applied at the provider boundary so lower levels never produce a rejected request.

## OpenRouter

OpenRouter is a first-party provider (api `openrouter-completions`) that speaks OpenAI Chat Completions against `https://openrouter.ai/api/v1`, authenticated by `OPENROUTER_API_KEY`.

```sh
export OPENROUTER_API_KEY=sk-or-...
fen --provider openrouter
```

The catalog is curated: fen fetches OpenRouter's `GET /models` but offers only its shipped list of tool-capable models that are live there, never the full catalog.
`/model` shows that list; the first entry is the default, and an off-list `--model` fails headless validation like any other catalog provider.
OpenRouter ids contain a slash, so pass either the canonical `--model openrouter/anthropic/claude-sonnet-5` or `--provider openrouter --model anthropic/claude-sonnet-5`; an explicit `--provider` that differs from the prefix keeps the whole value as the model id.
A prefix equal to the provider is always read as the canonical form, so ids that start with `openrouter/` are spelled `openrouter/openrouter/auto`.

Add or replace models with a `models.json` provider that uses the same api.
Its `models` list is offered in full and in order, including ids missing from the public catalog such as `:nitro` route variants and private or BYOK models; ids found there (a variant through its base id) pick up the live metadata:

```json
{
  "providers": {
    "openrouter": {
      "api": "openrouter-completions",
      "baseUrl": "https://openrouter.ai/api/v1",
      "apiKey": "OPENROUTER_API_KEY",
      "models": [{"id": "anthropic/claude-sonnet-5"}, {"id": "x-ai/grok-4.7"}]
    }
  }
}
```

Request policy the adapter applies:

- `--thinking` maps to OpenRouter's normalized `reasoning` object and never to top-level `reasoning_effort`: `minimal` through `xhigh` send `reasoning.effort`, while `off` and no thinking setting send no `reasoning` object and leave the model default.
  `--reasoning-effort` also accepts OpenRouter's `max`, and `--reasoning-effort none` is the explicit way to send `reasoning.enabled: false`, which models whose reasoning is mandatory (for example current Gemini models) reject.
  `--thinking-budget N` sends `reasoning.max_tokens`.
- A model whose live catalog entry does not list `reasoning` among its supported parameters gets no `reasoning` object, since `provider.require_parameters` would leave it no endpoint; support is learned when the catalog is fetched (headless `--model` validation or `/model`), and an unchecked model still gets one.
- `reasoning_details` from each response are kept on the turn's thinking block and echoed back unchanged on the assistant message, so thinking models keep Gemini thought signatures and Anthropic signed thinking across tool calls.
- Requests for `anthropic/*` and `google/*` models carry `cache_control: {type: "ephemeral"}` breakpoints on the system prompt and the latest user or tool message; cache reads and writes are reported as `cache-read` and `cache-write` usage.
- `provider.require_parameters` is always set so OpenRouter routes only to endpoints that honor tools and reasoning; for that reason the limit goes out as `max_tokens` and the default `parallel_tool_calls` is omitted.
- The session id goes out as `session_id` for sticky routing, and `HTTP-Referer`/`X-OpenRouter-Title` attribute traffic to fen.
- An error that arrives mid-stream is reported with OpenRouter's message instead of a bare `finish_reason: error`.

## Provider readiness and connectivity

`fen list providers --json` is offline discovery.
It loads the live provider registry but does not open a session, request a completion, or contact provider endpoints.
Each provider row includes `registered`, `configured`, `readiness`, and `connectivity` fields:

- `registered` means the provider extension is loaded in the current process.
- `configured` means its local API-key or auth-backend requirement is satisfied; authless providers are configured by definition.
- `readiness.status` is `ready` or `not-configured`, with a secret-free reason such as `configured`, `missing`, `authless`, `error`, or `backend-missing`.
- Offline output reports `connectivity.status` as `not-checked`.

Use the explicit networked check when endpoint reachability matters:

```sh
fen list providers --check --json
fen list providers --provider openai --check --json
```

The check uses each provider's existing model-catalog request and never sends a model-completion request.
It reports each provider independently as `reachable`, `unreachable`, `not-checked` (local configuration is missing), or `not-supported` (the provider has no model-catalog probe).
Failure reasons are stable categories such as `authentication-failed` and `request-failed`; response bodies, credentials, bearer tokens, and raw provider errors are never included.
A successful check establishes only that the catalog endpoint accepted the current configuration at that moment.

## Provider interface

Each provider module exports a record with at minimum:
`{:api :provider :complete :convert-messages :convert-tools :map-stop-reason
  :parse-response :build-body}`.

Provider registrations may also include `:models`, `:default-model`, and an optional `:list-models` function.
`:list-models` receives provider options such as resolved `:api-key`, `:base-url`, the provider's configured `:models`, and cooperative `:yield`, and returns model entries shaped like `{:id "model-id"}`.
Fen caches dynamic list results until `/reload` and falls back to static model metadata if listing fails.

Register through the extension API with `api.register :provider` (and
optionally `api.register :auth-backend`). The agent dispatches via
`(llm.complete agent.provider-api model context options)`. Adding another
provider = add or install an extension that registers a provider record.

OpenAI Chat Completions does **not** return thinking content even for
reasoning models (o-series, GPT-5). When that's needed, use the sibling
`provider-openai/openai_responses.fnl` rather than overloading
`openai_completions.fnl`.

OpenAI-compatible Responses wire conversion and SSE reduction live in
`extensions/adapters/providers/openai/openai_responses_shared.fnl`.
The reducer preserves OpenAI reasoning items as canonical `:thinking` blocks, streaming both `response.reasoning_summary_text.delta` and `response.reasoning_text.delta` when the provider exposes visible reasoning text.
The first-party OpenAI extension is a provider-family extension.
It registers API-key Chat Completions, API-key Responses, ChatGPT/Codex subscription Responses, and the Codex OAuth auth backend from one reload boundary.
For the ChatGPT/Codex subscription provider, fen queries the private ChatGPT backend `GET /backend-api/codex/models?client_version=0.200.0` catalog when OAuth credentials are configured and keeps list-visible models marked `supported_in_api`.
It also exposes the pinned `gpt-5.6-luna`, `gpt-5.6-sol`, and `gpt-5.6-terra` IDs while those models are absent from the account catalog; live catalog metadata takes precedence when those IDs appear.
It falls back to the shipped default if the catalog is unavailable.
The `openai-codex` provider defaults to `gpt-6.1-sol` unless a saved or explicit model preference overrides it.

## Codex account quota

The OpenAI extension owns the discoverable `account_usage` tool, which reads account-wide subscription quota rather than conversation token totals or context-window capacity.
Activate it through `tool_search` and call it with `{}` for a bounded demand refresh using existing Codex OAuth credentials and `fen.util.http.request`.
The authenticated read-only `GET https://chatgpt.com/backend-api/wham/usage` was verified on 2026-10-05 to expose `rate_limit.primary_window` and `rate_limit.secondary_window` with `used_percent`, `limit_window_seconds`, `reset_at` (Unix epoch seconds), and `reset_after_seconds` (seconds until reset).
The observed window lengths were 18000 seconds (five hours) and 604800 seconds (seven days); lengths are parsed, not hard-coded.
No `x-codex-*` response headers or exact remaining-token counts were observed, so neither is assumed or synthesized.
Only validated primary/secondary windows under `rate_limit` and `code_review_rate_limit` are supported in this phase; other allowances and model-specific quotas are not inferred.
The sanitized snapshot has `provider`, `scope: account-quota`, `windows` (each with `name`, `used-percent`, `remaining-percent`, `length-seconds`, and `reset-at`), `retrieved-at`, `attempted-at`, `status`, and optional `failure`.
Timestamps are Unix epoch seconds, and percentages are upstream percentages with remaining calculated as 100 minus used.
`fresh` means the last successful retrieval is younger than 60 seconds, no known failure occurred, and no reported window has reset; otherwise retained windows are `stale`.
Without usable windows, the status is `unavailable` for auth/network/API failures or before retrieval, and `unsupported` for HTTP 404/405 or a successful JSON object with supported quota groups/windows absent or null.
Present but malformed supported windows, groups, or response envelopes are `api` failures, retaining stale cached windows when available rather than claiming unsupported quota.
Failures expose only `auth`, `network`, `api`, `unsupported`, or the initial `unavailable` marker, never exception text, raw responses, credentials, or account identifiers.
Attempts are limited to once per 60 seconds, including failed or cancelled attempts, with no background polling or retries.
A demand refresh allows at most one existing OAuth refresh (30-second HTTP timeout) followed by one usage GET (10-second timeout), passing the cooperative tool yield callback through both and preserving cancellation.
The sanitized cache survives `/reload` and restart in one versioned JSON file at `${XDG_STATE_HOME:-~/.local/state}/fen/codex-usage.json`.
Its version-1 envelope contains `version`, `account-key` (a SHA-256 hash of the OAuth account id), and `snapshot` containing only the sanitized fields described above; raw account ids, emails, tokens, and response bodies are never written.
Writes use a unique sibling temporary file and atomic rename; missing, corrupt, newer-version, or account-mismatched cache files are ignored.
Cached startup windows are always shown stale, without network access, and disk `attempted-at` carries the 60-second demand floor across processes.
An extension-owned stable `codex-usage.json.lock` inode uses an OS advisory write lock around reading, checking, and persisting the attempt; the existing process-local file mutex also serializes coroutines.
Contention yields cooperatively (or sleeps in synchronous calls) for at most one second, then skips the refresh; failed persistence also skips network access, and closing the lock file releases ownership on errors or cancellation.
The lock inode is retained rather than deleted, and the kernel releases ownership if a process exits.
A changed or missing local account discards the previous account's in-memory cache on the next demand refresh; stale windows are not a promise of current allowance.
`agent_state` collects the same cached snapshot under owner `provider_openai`, name `account-usage`, through the existing introspection interface without reading credentials or touching the network.
For the active Codex provider, the TUI status row shows quota remaining for the reported windows, labeled by their parsed duration, such as `5h:78% 7d:95%`.
The quota helper falls back to the window with the least remaining quota, but the left/order-21 status contribution can be clipped entirely after earlier left items and the right-side reservation at narrow widths.
`~` identifies stale status data; the current status renderer does not support muted styling, although the detail panel does.
Yellow warns below 25% remaining, and red warns below 10%.
After a reported reset time passes, the display shows 100% rather than repeating the old percentage; this is a reset indication, not a new upstream measurement.
`/usage` toggles a dismissible below-status panel with proportional remaining bars, relative reset times, and retrieval age or sanitized failure category.
`Esc` or another `/usage` closes it, and unsupported quota or authentication failures get an explanation instead of bars.
Opening the panel requests a bounded cooperative demand refresh; rendering, ordinary turns, and runtime ticks never initiate quota requests on their own.
Additional upstream quota shapes remain follow-ups.

## Wire-shape differences

The agent loop only ever sees canonical messages; each provider converts to and
from wire shape at the boundary and absorbs these differences:

- **Auth headers.** OpenAI uses `Authorization: Bearer <key>`; Anthropic uses
  `x-api-key: <key>` plus `anthropic-version: 2023-06-01`. Owned by the provider
  modules.
- **System prompt placement.** OpenAI inlines it as `messages[0].role:"system"`;
  Anthropic uses a top-level `system` field. The agent always carries
  `system-prompt` separately on `AgentContext` and lets the provider place it.
- **Tool result shape.** OpenAI emits a standalone `{role:"tool", tool_call_id,
  content}` message; Anthropic nests a `tool_result` content block inside a
  `{role:"user"}` message and batches consecutive `:tool-result` canonical
  messages into one user message.
- **Tool history without tools.** A tool-less request (for example `--continue --no-tools` or `fen session send --no-tools` on a session with tool history) can still replay earlier tool calls and results.
  Anthropic rejects `tool_use`/`tool_result` blocks unless tools are defined, so its adapter declares inert stub tools named after the calls in history and sets `tool_choice: none`.
  The OpenAI Chat Completions and Responses adapters (including Codex and Sakana) send that history unchanged.
- **Per-step tool choice.** `agent.step` accepts `{:tool-choice :none}` as its fourth argument; the loop forwards it as the `:tool-choice` provider option on every request in that step.
  Tool definitions stay in the request and each adapter maps it natively: Anthropic `tool_choice: {type: "none"}`, OpenAI Chat Completions and Responses (including Codex and Sakana) `tool_choice: "none"`.
  Anthropic accepts `tool_choice: none` alongside extended thinking.
  Tool calls that arrive anyway are not executed; each gets a paired synthetic error result, the model gets one more turn to answer in text, and a second refused turn ends the step with an error.
- **Tool args are parsed objects** in the canonical type, not JSON strings. Each
  provider's `parse-response` JSON-decodes the wire arguments before building the
  canonical `:tool-call` block, so a tool's `execute` receives a ready-to-use Lua
  table.

## HTTP transport and TLS trust

All provider HTTP, including Codex OAuth login and refresh, goes through `fen.util.http`.
The default backend is fen's project-owned `fen_http` C module (built from `packages/util/vendor/fen_http.c`), which wraps libcurl; fen does not shell out to `curl(1)` or use the old `lua-curl` rock. JSON uses `lua-cjson`, loaded as `cjson`.

Timeout defaults (600000 ms overall, 30000 ms connect, 60000 ms idle-stall watchdog) are applied once in `fen.util.http.request` before dispatch, so every backend treats the timeout fields as always-present rather than re-implementing the policy. The C backend keeps matching literals only as a harmless last resort.

A successful response's `:headers` maps each field name, in the server's casing, to one string from the final response only; 1xx interim and proxy CONNECT header blocks are dropped.
A field repeated under the same name joins its values in wire order with `", "` (RFC 9110), except `Set-Cookie`, which joins with `"\n"` because cookie values may contain commas.
Transport failures carry `:curl-code` only for libcurl `CURLE_*` codes; a curl multi-interface failure names its `CURLMcode` in `:error` and sets no `:curl-code`, so the retry layer never misreads it.

A backend may export a `:capabilities` table alongside `:request` to declare what its transport can do; absent capabilities means the fen_http.so default (blocking allowed). The only capability today is `:blocking?`: a cooperative-only backend (e.g. a browser/event-loop fetch backend) declares `{:blocking? false}`, and `fen.util.http.request` then fails fast before dispatch when a caller passes no `:yield`, returning the canonical structured error `{:error string :capability "blocking"}` instead of each backend inventing its own guard.

By default, libcurl uses its compiled-in/platform CA lookup.
For devices with an unusual or stale trust store, set a bundle-file override before starting fen:

```sh
export CURL_CA_BUNDLE=/path/to/ca-bundle.crt
# or, if CURL_CA_BUNDLE is unset/empty:
export SSL_CERT_FILE=/path/to/ca-bundle.crt
```

`CURL_CA_BUNDLE` takes precedence over `SSL_CERT_FILE`.
When neither variable is set, fen leaves CA discovery to libcurl.

## Thinking controls

Use `--thinking LEVEL` for provider-neutral thinking control.
Accepted levels are `off`, `minimal`, `low`, `medium`, `high`, and `xhigh`.
Anthropic maps levels to coarse `thinking-budget` token buckets; OpenAI Responses, Codex Responses, and Chat Completions map levels to `reasoning-effort` / `reasoning_effort`.
Every provider also receives any level other than `off` as the `:thinking-level` option, so an adapter that owns its mapping, such as [OpenRouter](#openrouter), needs no per-API table in core.
`off` sends no thinking option at all, leaving the model default.

`--thinking-budget N` remains the exact Anthropic escape hatch and wins over `--thinking`.
`--reasoning-effort E` remains the exact OpenAI escape hatch and wins over `--thinking`.
Use `/thinking` in an interactive run to inspect the current level and provider materialization.
Use `/thinking LEVEL` to change the level for the current session and persist it as `defaultThinking` in `~/.config/fen/settings.json`.
Use `/thinking blocks on|off` to show or hide rendered thinking blocks without changing provider effort.
Fen can only render thinking text that the provider sends; Codex may return only encrypted reasoning continuity data, which is preserved for replay but has no visible text to show.

## Hosted web search

OpenAI's hosted `web_search` tool runs on the provider's servers, not through a local fen tool.
Only the Codex adapter (`openai-codex`) sends it for now; other providers ignore the setting.
It is off by default.
Turn it on for a run with `--web-search MODE` (on `fen`, `fen goal`, and `fen session send`), or by default with `defaultWebSearch` in `~/.config/fen/settings.json`.
The flag wins over the setting, and an invalid setting is logged and ignored.

- `off` sends no hosted tool.
- `cached` searches OpenAI's index only and cannot open pages the index has not seen; it is the safer mode.
- `live` may also fetch arbitrary live pages (`open_page` and `find_in_page` actions).

Privacy: the model writes search queries from your private context, so that context can leave in a query.
In `live` mode, a prompt injection (for example in a file or tool output) can steer the model to fetch an attacker-chosen URL with data in its query string.

Cost: while enabled, every request carries about 4.4k extra input tokens for the tool definition, whether or not the model searches, and each search adds roughly 1–5 s.
The TUI busy row shows `searching the web` while a search runs and adds a `web search: <query>` row when it finishes.

Citations are the inline markdown links the model writes into its answer; fen keeps that text but drops the structured `url_citation` annotations.
Search calls and their results are not replayed on later turns (requests use `store: false`), so the model may search again for something it already found.

Hosted tools ride only with agent tools:

- `--no-tools` with `cached` or `live` is rejected, and `--no-tools` skips `defaultWebSearch`.
- Compaction and handoff summaries never search.
- A `tool_choice: none` turn keeps the tool in the request but cannot call it.
- Subagent children do not inherit `--web-search`; they read `defaultWebSearch` like any run.
- A TUI `/btw` side chat keeps the main session's mode alongside its read-only tools and drops it when it is tool-less.

## Latency

On reasoning models the dominant per-turn cost is prefill / time-to-first-token, not generation speed.
Three knobs move it, in the order worth reaching for:

1. **Reasoning effort** — the largest server-side lever.
   Lower effort means fewer hidden reasoning tokens, which is what drives the slow tail of a turn.
   It is the first knob to reach for when turns feel slow: lower `--thinking` (e.g. `low`/`minimal`), or set `--reasoning-effort` directly.
   The default is **off** — fen sends no `reasoning_effort` unless you pass `--thinking`/`--reasoning-effort` or set `defaultThinking` in settings — so a slow default is almost always a configured `defaultThinking`, not a built-in.
2. **Connection reuse** — fen pools the TCP connection, TLS session, and DNS cache across turns (a process-global libcurl share handle plus TCP keepalive), so a warm connection skips the handshake on the next turn.
   This is automatic; it matters most on Pi-class hardware where a TLS handshake is hundreds of ms.
3. **Prompt caching** — fen sets a stable `prompt_cache_key` (the session id) so the provider keeps routing a session's turns to the same warm cache.
   Caching still misses when the prompt prefix changes (e.g. after `/compact`, or a model switch that reshapes the transcript), so it is a best-effort hint, not a guarantee.

`/status` shows the last turn's measured latency and output tok/s so you can see the effect of these knobs.

## Custom providers (models.json)

OpenAI-compat HTTP endpoints (Ollama local, Ollama Cloud, vLLM, LM Studio,
proxies) are configured via `~/.config/fen/models.json` — read by
`packages/core/src/fen/core/llm/models.fnl` at first call and cached until `/reload` re-requires
the module. Mirrors the floor of pi-mono's `models.json` schema (see
`pi-mono/packages/coding-agent/docs/models.md`).

Field handling:
- `apiKey` is resolved via a heuristic: UPPER_SNAKE_CASE values → `os.getenv`,
  anything else → literal. **No `!shell-cmd` support.**
- `baseUrl` may be either the v1 root (`http://localhost:11434/v1`) or the
  full POST endpoint — `openai_completions.build-url` appends
  `/chat/completions` only when the path doesn't already end in it.
- `compat` is passed verbatim into `provider-options` and consumed by
  `build-body`. Today only `compat.maxTokensField` is honored (Ollama needs
  `"max_tokens"`); other keys are accepted forward-compatibly.

Deliberately skipped vs pi-mono: `!shell-cmd`, `modelOverrides`, per-model
`compat`, cost/pricing fields, image input declarations, and a dedicated
`models.json` reload command. Reload provider config via `/reload`.

Custom provider definitions live in `~/.config/fen/models.json`; persistent user preferences live separately in `~/.config/fen/settings.json`. The latter currently stores `defaultProvider`, `defaultModel`, `defaultThinking`, `defaultWebSearch` (see [Hosted web search](#hosted-web-search)), `pinnedTools` (camelCase on disk, kebab-case internally), and per-extension `extensions` settings (see [extensions.md](extensions.md#discovery)). CLI `--provider`/`--model`/`--thinking` flags win, exact thinking overrides win over `--thinking`, then settings defaults apply, then the built-in `openai` and thinking-off fallbacks. Bare `/model` opens the configured-model selector, and a non-exact `/model QUERY` opens it with `QUERY` as the initial search text when a UI is active; exact model IDs and numeric indexes switch directly. The `/model` command writes provider/model settings after a successful switch, and `/thinking LEVEL` writes `defaultThinking`. Do not put mutable preferences in `models.json`.

In non-interactive modes (`--print` and the `json`/`goal` presenters, which have no `/model` selector to recover with), an explicit `--model` id is validated client-side against the selected provider's catalog before any request is sent.
An exact id, canonical `provider/id`, or unambiguous substring/fuzzy match is accepted (a fuzzy match is echoed on stderr and rewritten to its canonical id); an unknown or ambiguous id fails fast with exit code 2 and a `did you mean:` suggestion list drawn from the catalog, instead of forwarding the bad id and surfacing a provider HTTP error.
When the catalog cannot be consulted — an unregistered provider, missing auth, or a provider that only knows its default because its dynamic catalog is unreachable and it declares no static models — the id is passed through unchanged.

First-party providers may expose dynamic model catalogs.
Fen caches successful or failed catalog lookups until `/reload`, so model selection does not repeatedly hit provider APIs.

The read-only `models` agent tool uses the same cached discovery path as `/model`.
Its `current`, `providers`, and `list` actions expose the active model, registered-provider availability, secret-free authentication status, and selectable model IDs.
Authentication status never includes keys or OAuth credentials; it reports only states such as `configured`, `missing`, `authless`, `error`, or `backend-missing`.
Unlike `/model`, provider inspection retains unavailable providers so an agent can explain why a model cannot be selected.

The auth header is **omitted entirely** when api-key is nil/empty so auth-less local servers don't get a stray `Authorization: Bearer ` line.

Minimal local Ollama example:

```json
{
  "providers": {
    "ollama": {
      "baseUrl": "http://localhost:11434/v1",
      "api": "openai-completions",
      "apiKey": "ollama",
      "compat": {"maxTokensField": "max_tokens"},
      "models": [{"id": "llama3.1:8b"}]
    }
  }
}
```

## Mock provider (deterministic, scriptable)

The first-party `provider_mock` extension is a deterministic provider that returns canonical assistant messages with no network I/O.
It exists for tests, smoke runs, and offline dev: the agent loop, tool dispatch, and TUI all run unchanged, but every turn is reproducible.
It requires no credentials, so startup never prompts for an API key.

It ships **off by default**.
Enable it for a run with `--extension` pointing at its source directory, then select it:

```sh
fen --extension extensions/adapters/providers/mock --provider mock --model mock
```

Tests register the provider directly instead, and never need the extension machinery.

### Scripting responses

Responses come from a *script*, resolved in this order:

1. the `mock-script` provider option — a path string, or an already-loaded sequence/function (used by in-process tests);
2. the `FEN_MOCK_SCRIPT` environment variable — a path to a `.fnl` or `.lua` file (the CLI / smoke / dev knob);
3. no script — echo the last user message back as `[mock] <text>`.

A loaded script is either a **sequence of turns** or a **function** `(fn [req] turn)`.
A sequence is replayed one turn per assistant turn; the index is the number of assistant messages already in context plus one.
That makes replay stateless and `/reload`-safe — there is no cursor to keep — and indexing past the end yields a `[mock] script exhausted` turn.
A function receives `req = {:messages :tools :system-prompt :model :options :turn}` for programmable or rule-based responses.

A *turn* is a string (shorthand for visible text) or a table:

```fennel
;; FEN_MOCK_SCRIPT=session.fnl — a two-turn scripted run.
[;; turn 1: call a tool
 {:tool-call {:id "c1" :name :read :args {:path "README.md"}}}
 ;; turn 2: after the tool result comes back, finish
 "Done — README starts with a title."]
```

Recognized turn keys: `:text`, `:thinking`, `:tool-call {:id :name :args}`, `:tool-calls [...]`, `:error`, and a raw `{:content [...] :stop-reason :usage}` passthrough.
`:stop-reason` defaults to `:tool-use` when the turn calls a tool, otherwise `:stop`.
A function script can echo or branch on the conversation:

```fennel
;; FEN_MOCK_SCRIPT=echo.fnl — programmable rule-based mock.
(fn [req]
  (let [last (. req.messages (length req.messages))]
    (if (= last.role :tool-result)
        "Thanks, that's all I needed."
        {:text (.. "turn " req.turn)})))
```

The sequence form derives its index from the assistant-message count in the context the provider receives.
The agent transforms that context before each call (for example, it excludes errored assistant turns), so a sequence can desync across turns.
When that happens, use the function form with closure state to count actual provider calls.

### Recording what the agent sent

Pass a table on the `mock-record` provider option to capture each outbound call.
The provider appends `{:model :options :context {:system-prompt :tools :messages}}` per call, with `messages` shallow-copied at call time (the agent mutates its message list in place across loop iterations).
This lets a test assert on the request — system prompt placement, the canonical `Tool[]` sent, message conversion, steering injection — not just the returned message.

```fennel
(local rec [])
;; ... make-agent {... :provider-options {:mock-script [...] :mock-record rec}}
;; after a step:
(assert.are.equal "you are a test" (. rec 1 :context :system-prompt))
```

`extensions/adapters/providers/mock/tests/agent_loop_test.fnl` drives the real agent loop through the mock this way; the cooperative/transport/cancellation contract that must program the dispatcher directly stays in `packages/core/tests/agent_test.fnl`.


