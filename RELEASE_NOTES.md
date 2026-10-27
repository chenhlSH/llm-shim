# llm-shim v0.2.1

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
| `llm-shim-v0.2.1-linux-x86_64.tar.gz` | Linux x86_64 |
| `llm-shim-v0.2.1-macos-aarch64.tar.gz` | macOS Apple Silicon |
| `llm-shim-v0.2.1-windows-x86_64.zip` | Windows x86_64 |
| `SHA256SUMS.txt` | checksums for the three archives |

Each archive contains the binary, `LICENSE` (MIT) and `README.md`. Any other platform:
build from source with `zig build -Doptimize=ReleaseSafe` (see README).

## Quickstart

```sh
tar xzf llm-shim-v0.2.1-linux-x86_64.tar.gz
export INTERN_AI_API_KEY=sk-...        # vendor key (built-ins: InternAI, AMD Radeon)
./llm-shim serve                       # gateway on http://127.0.0.1:8686
```

Point any client at `http://127.0.0.1:8686`, pick the API format it speaks natively,
model name `provider/model` (e.g. `intern-ai/glm-5.3`). Details: README / 使用文档.

Verify checksums: `sha256sum -c SHA256SUMS.txt` (run in the directory with the archives).

## Highlights of 0.2.1

- **Cline Pass compatibility**: top-level `providerOptions` in chat requests (e.g.
  `gateway.only` / `gateway.has`) is forwarded verbatim to openai-dialect upstreams, and upstream
  `provider_metadata` (e.g. `gateway.routing.finalProvider`) is passed back to the client intact —
  streaming: injected into the next chunk's top level; non-streaming: top level of the response.
  Dropped on translation paths (anthropic/responses upstreams).

## Carried from 0.2.0

- Streaming flush fix (headers + SSE frames pushed to the socket immediately).
- Three-dialect fallback ring, 600s upstream idle timeout, strict CLI, request-id diagnostics,
  spec-complete failure signals and Responses SSE events.
