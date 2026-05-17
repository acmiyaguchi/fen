# Providers and models

Provider-facing contracts, wire-shape differences, and custom model configuration.

## Provider interface

Each provider module exports a record with at minimum:
`{:api :provider :complete :convert-messages :convert-tools :map-stop-reason
  :parse-response :build-body}`.

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

## HTTP transport and TLS trust

All provider HTTP, including Codex OAuth login and refresh, goes through `fen.util.http`.
The default backend is fen's project-owned `fen_http` C module, which wraps libcurl; fen does not shell out to `curl(1)` and does not use the old `lua-curl` rock.

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

Custom provider definitions live in `~/.config/fen/models.json`; persistent user preferences live separately in `~/.config/fen/settings.json`. The latter currently stores `defaultProvider`, `defaultModel`, and `defaultThinking` (camelCase on disk, kebab-case internally). CLI `--provider`/`--model`/`--thinking` flags win, exact thinking overrides win over `--thinking`, then settings defaults apply, then the built-in `openai` and thinking-off fallbacks. The `/model` command writes provider/model settings after a successful switch, and `/thinking LEVEL` writes `defaultThinking`. Do not put mutable preferences in `models.json`.

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


