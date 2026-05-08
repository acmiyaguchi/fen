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
The first-party OpenAI extension is a provider-family extension.
It registers API-key Chat Completions, API-key Responses, ChatGPT/Codex subscription Responses, and the Codex OAuth auth backend from one reload boundary.


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
`compat`, cost/pricing fields, image input declarations, the `/model`
slash command. Reload via `/reload`, not a dedicated config-only command.

Custom provider definitions live in `~/.config/fen/models.json`; persistent user preferences live separately in `~/.config/fen/settings.json`. The latter currently stores `defaultProvider` and `defaultModel` (camelCase on disk, kebab-case internally). CLI `--provider`/`--model` flags win, then settings defaults, then the built-in `openai` fallback. The `/model` command writes settings after a successful switch. Do not put mutable preferences in `models.json`.

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


