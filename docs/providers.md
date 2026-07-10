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
fen providers sakana
fen providers ollama
```

The short path for built-ins is:

```sh
export OPENAI_API_KEY=sk-...          # openai or openai-responses
export ANTHROPIC_API_KEY=sk-ant-...  # anthropic
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

## Provider interface

Each provider module exports a record with at minimum:
`{:api :provider :complete :convert-messages :convert-tools :map-stop-reason
  :parse-response :build-body}`.

Provider registrations may also include `:models`, `:default-model`, and an optional `:list-models` function.
`:list-models` receives provider options such as resolved `:api-key`, `:base-url`, and cooperative `:yield`, and returns model entries shaped like `{:id "model-id"}`.
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
For the ChatGPT/Codex subscription provider, fen queries the private ChatGPT backend `GET /backend-api/codex/models?client_version=0.124.0` catalog when OAuth credentials are configured and keeps list-visible models marked `supported_in_api`.
It also exposes the pinned `gpt-5.6-luna`, `gpt-5.6-sol`, and `gpt-5.6-terra` IDs while those models are absent from the account catalog; live catalog metadata takes precedence when those IDs appear.
It falls back to the shipped default if the catalog is unavailable.

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
- **Tool args are parsed objects** in the canonical type, not JSON strings. Each
  provider's `parse-response` JSON-decodes the wire arguments before building the
  canonical `:tool-call` block, so a tool's `execute` receives a ready-to-use Lua
  table.

## HTTP transport and TLS trust

All provider HTTP, including Codex OAuth login and refresh, goes through `fen.util.http`.
The default backend is fen's project-owned `fen_http` C module (built from `packages/util/vendor/fen_http.c`), which wraps libcurl; fen does not shell out to `curl(1)` or use the old `lua-curl` rock. JSON uses `lua-cjson`, loaded as `cjson`.

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

`--thinking-budget N` remains the exact Anthropic escape hatch and wins over `--thinking`.
`--reasoning-effort E` remains the exact OpenAI escape hatch and wins over `--thinking`.
Use `/thinking` in an interactive run to inspect the current level and provider materialization.
Use `/thinking LEVEL` to change the level for the current session and persist it as `defaultThinking` in `~/.config/fen/settings.json`.
Use `/thinking blocks on|off` to show or hide rendered thinking blocks without changing provider effort.
Fen can only render thinking text that the provider sends; Codex may return only encrypted reasoning continuity data, which is preserved for replay but has no visible text to show.

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

Custom provider definitions live in `~/.config/fen/models.json`; persistent user preferences live separately in `~/.config/fen/settings.json`. The latter currently stores `defaultProvider`, `defaultModel`, and `defaultThinking` (camelCase on disk, kebab-case internally). CLI `--provider`/`--model`/`--thinking` flags win, exact thinking overrides win over `--thinking`, then settings defaults apply, then the built-in `openai` and thinking-off fallbacks. Bare `/model` opens the configured-model selector, and a non-exact `/model QUERY` opens it with `QUERY` as the initial search text when a UI is active; exact model IDs and numeric indexes switch directly. The `/model` command writes provider/model settings after a successful switch, and `/thinking LEVEL` writes `defaultThinking`. Do not put mutable preferences in `models.json`.

First-party providers may expose dynamic model catalogs.
Fen caches successful or failed catalog lookups until `/reload`, so model selection does not repeatedly hit provider APIs.

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


