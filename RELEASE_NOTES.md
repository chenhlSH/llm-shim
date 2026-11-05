# llm-shim v0.3.0

A local LLM API compatibility gateway + connectivity probe in a **single binary**
(Zig 0.17, standard library only, zero third-party dependencies).

Client SDKs speak three dialects — OpenAI Chat Completions, OpenAI Responses, Anthropic
Messages. Vendors support arbitrary subsets of them. `llm-shim` sits on `127.0.0.1:8686`,
accepts any of the three, and makes them work: missing upstream routes are translated
automatically (three-dialect fallback ring), vendor quirks (reasoning-effort flags, error
envelopes, rate limits, spec-incomplete SSE events) are shielded, long upstream silence is
bridged with an invisible keepalive, and every request gets a traceable diagnostic chain.

## Assets

| Asset | Platform |
|---|---|
| `llm-shim-v0.3.0-linux-x86_64.tar.gz` | Linux x86_64 |
| `llm-shim-v0.3.0-macos-aarch64.tar.gz` | macOS Apple Silicon |
| `llm-shim-v0.3.0-windows-x86_64.zip` | Windows x86_64 |
| `SHA256SUMS.txt` | checksums for the three archives |

Each archive contains the binary, `LICENSE` (MIT) and `README.md`. Any other platform:
build from source with `zig build -Doptimize=ReleaseSafe` (see README).

## Quickstart

```sh
tar xzf llm-shim-v0.3.0-linux-x86_64.tar.gz
export INTERN_AI_API_KEY=sk-...        # vendor key (built-ins: InternAI, AMD Radeon)
./llm-shim serve                       # gateway on http://127.0.0.1:8686
```

Point any client at `http://127.0.0.1:8686`, pick the API format it speaks natively,
model name `provider/model` (e.g. `intern-ai/glm-5.3`). Details: README / 使用文档.

Verify checksums: `sha256sum -c SHA256SUMS.txt` (run in the directory with the archives).

## Highlights of 0.3.0

- **Free upstream providers, built in**: Groq, GitHub Models, Google Gemini, Tencent Hunyuan
  (`hunyuan-lite`) and Zhipu BigModel (`glm-4.7-flash` / `glm-4.6v-flash`) are now built-in
  providers — they register **only when their API key env is set** (`GROQ_API_KEY`,
  `GITHUB_MODELS_TOKEN`, `GEMINI_API_KEY`, `HUNYUAN_API_KEY`, `ZHIPU_API_KEY`), so `/providers`
  and `/models` stay clean otherwise. `<KEY>_BASE_URL` points any built-in at a self-hosted proxy.
  Model catalogs are discovered online at load time (static fallback table on failure).
- **New probe presets**: Mistral (free tier) and Alibaba Bailian (90-day trial quota); new path
  candidates `/v1beta/openai` (Gemini compat) and `/inference` (GitHub Models).
- **Toolchain**: built with Zig 0.17.1 (`minimum_zig_version` raised); 0.17.1 is a bug-fix-only
  patch — none of our documented std workarounds were removed.

## Carried from earlier

- Three-dialect fallback ring, 600s upstream idle timeout, placeholder keepalive, strict CLI,
  request-id diagnostics, Cline Pass compatibility (`providerOptions` passthrough +
  `provider_metadata` round-trip), spec-complete failure signals and Responses SSE events.
