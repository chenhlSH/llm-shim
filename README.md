# llm-shim

A local LLM API compatibility gateway + connectivity probe in a **single binary** (Zig 0.17, standard library only, zero third-party dependencies).

> 中文文档：[README.zh.md](README.zh.md)（架构与规则） · [使用文档.md](使用文档.md)（上手指南） · [NOTES.zh.md](NOTES.zh.md)（工程笔记）

## What it does

Client SDKs speak three dialects — OpenAI Chat Completions, OpenAI Responses, Anthropic Messages.
Upstream vendors support arbitrary subsets of them, and each vendor has its own quirks
(reasoning-effort flags, error envelopes, rate limits, missing routes). `llm-shim` sits on
`127.0.0.1:8686`, accepts any of the three dialects, and makes them work:

- **Three-dialect fallback ring** — if the dialect your client demands keeps failing upstream
  (5xx / 429 / timeout / missing route), the gateway translates the same request to another
  dialect the vendor actually serves, and translates the answer back. The client never changes.
  Broken dialects are remembered for 300s, then retried.
- **Vendor quirk shielding** — reasoning-effort negotiation (rejected flag → accepted flag,
  remembered per model), transient 5xx/429 retry with backoff, canonical error envelopes,
  spec-complete SSE events (strict clients drop malformed events silently).
- **Placeholder keepalive** — during long upstream silence the gateway injects an invisible
  sentinel-wrapped `…` into the SSE stream to feed the client's idle timer; it is stripped
  by exact string match before anything is forwarded upstream (structure untouched, so
  upstream prefix caches stay warm).
- **600s upstream idle timeout** — black-holed upstreams fail bounded with `code=TIMEOUT`
  instead of hanging forever.
- **Connectivity probe** (`llm-shim probe`) — verifies API keys, discovers the correct
  endpoint path, and writes a ready-to-use `providers.json`.
- **Strict CLI** — one obvious spelling per option; unknown/misspelled/redundant/conflicting
  arguments are rejected with the correct command printed (no silent fallbacks).
- **Diagnostics** — every request gets an id (honors client `x-request-id`); logs cover inbound
  summary, per-upstream-attempt status/code/elapsed/error snippet, and a terminal summary.

## Quickstart

```sh
# 1. get a binary (or build, see below)
# download the asset for your platform from https://github.com/chenhlSH/llm-shim/releases
tar xzf llm-shim-v0.2.0-linux-x86_64.tar.gz      # linux (x86_64)
tar xzf llm-shim-v0.2.0-macos-aarch64.tar.gz     # macos (Apple Silicon)
unzip llm-shim-v0.2.0-windows-x86_64.zip         # windows (x86_64)

# 2. export your vendor keys (built-ins: InternAI Discovery, AMD Radeon Cloud)
export INTERN_AI_API_KEY=sk-...

# 3. run the gateway (menu) or as a service
./linux/llm-shim          # interactive menu
./linux/llm-shim serve    # gateway only, for scripts

# 4. point your client at http://127.0.0.1:8686
#    model name: provider/model, e.g. intern-ai/glm-5.3
```

Optional: `./linux/llm-shim probe --key sk-... --base-url https://vendor.example` verifies
the key, finds the working endpoint, and freezes it into `providers.json`.

Point any client (zcode, Claude Code, anything OpenAI-compatible) at the gateway:

| Setting | Value |
|---|---|
| Base URL | `http://127.0.0.1:8686` (`/v1` optional — stripped) |
| API format | whichever the client speaks natively: Chat Completions · Responses · Anthropic Messages (missing upstream routes are translated automatically) |
| Model | `provider/model`, e.g. `intern-ai/glm-5.3` |
| API key | anything (gateway ignores it unless `AUTO_COMPAT_GATEWAY_TOKEN` is set; a client-supplied key is forwarded upstream) |

## Configuration (environment variables)

| Variable | Default | Meaning |
|---|---|---|
| `AUTO_COMPAT_GATEWAY_HOST` / `AUTO_COMPAT_GATEWAY_PORT` | `127.0.0.1` / `8686` | Listen address |
| `AUTO_COMPAT_GATEWAY_TOKEN` | empty (off) | Require this token via `Authorization` or `x-api-key` |
| `AUTO_COMPAT_PROVIDERS_FILE` | `providers.json` | Extra providers; entries with the same endpoint as a built-in are merged |
| `AUTO_COMPAT_PLACEHOLDER_MS` | `55000` | Keepalive threshold (streaming only); `0` disables |
| `AUTO_COMPAT_IDLE_TIMEOUT_MS` | `600000` | Upstream silence limit per attempt; `0` disables |
| `AUTO_COMPAT_RETRY_DELAY_MS` | `100` | Backoff scale factor (tests use `1`) |
| `AUTO_COMPAT_DEBUG` | unset | Verbose internal traces |

## Build

```sh
zig build -Doptimize=ReleaseSafe                      # native  -> zig-out/bin/llm-shim
zig build -Doptimize=ReleaseSafe -Dtarget=x86_64-windows-gnu --prefix zig-out/windows
zig build -Doptimize=ReleaseSafe -Dtarget=aarch64-macos       --prefix zig-out/macos
zig build test                                        # unit tests
python3 tests/e2e_selfheal.py                         # 19-scenario e2e (fake upstream, no network)
```

## License

[MIT](LICENSE)
