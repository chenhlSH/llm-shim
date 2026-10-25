#!/usr/bin/env python3
"""auto-compat-zig 运行时自愈 e2e：本地假上游 + 真网关进程，19 个确定性场景。

场景：
  1. path-only       裸站点，正确后缀 /api/v1（启动时上游不可达 → 运行时发现）
  2. openai-only     /messages、/responses 404 → 方言映射（anthropic 入站翻译为 openai）
  3. effort-reject   带 reasoning_effort 即 400（中文提示）→ 省略档位重试并记住
  4. transient       首次 500、二次 200 → 退避重试
  5. rate-limit      首次 429 + Retry-After: 1 → 等待重试
  6. auth            401 JSON → 不重试，原样上抛（AUTH）
  7. persist         场景 2 之后 providers.json 被写回固定路径；重启后直连固定路径
  8. tools           并行双工具 → Responses done 事件带全 id/name/arguments、各占一个 output_index
  9. ambiguity       ① 同端点条目装载期被忽略（内置优先 + 日志讲清楚）② 裸模型 id 歧义 400
                     列出候选并给出 provider/model 建议 ③ 裸站点解析后复核去重（先注册者优先）
  10. probe-exit     探针命中即停：不再轮询其余预设端点；用户 URL 全部试探、同端点只固化一条
  11. placeholder    上游静默 ≥ 阈值 → 网关向客户端注入伪装占位（隐形哨兵包裹的省略号，
                     发上游前剥离）；回灌历史 → 上游请求体无占位、裸省略号原样保留
  12. blackhole      上游 accept 后永不响应 → 看门狗空闲超时打断阻塞读 → TIMEOUT 有界失败
                     （重试耗尽后错误帧/信封；网关不挂死）
  13. client-key     入站携带的 api-key 直通上游（x-api-key / Authorization: Bearer；环境变量缺失时）；
                     环境变量优先；网关令牌绝不外传；两者都没有 → MISSING_CREDENTIAL 快失败不重试；
                     网关令牌支持 Authorization 与 x-api-key 两种载体（Anthropic 客户端标准）
  14. cli-strict     选项排列组合的严格解析（用户裁决"只有一种显而易见写法；显式优于隐式"）：
                     未知/缺失/空值/类型错/杂散参数/冗余写法（`--opt=VALUE`）/重复选项/矛盾组合
                     （双 key 来源、--no-verify 与验证类并存、--verify-models 0）/help 带参数/
                     `gateway` 别名/菜单文字别名 → exit 2 并给出正确指令，不触网不写文件；
                     顺序无关；选项产物一致；无效环境变量被点名；向导非数字/0/非 y-n 重问
  15. responses-fail  Responses 方言的失败信号是规范形状：流式 response.failed 带完整 Response 对象
                     （id/object/status=failed/model/output/error/usage，created/completed/failed 同 id）；
                     非流式走标准错误信封（顶层 error.message/type/code）；失败流不含 response.completed
  16. dialect-fallback 原生方言反复 5xx（厂商 /responses 坏而 chat 正常）→ 重试耗尽后换 primary 方言
                     翻译，客户端仍拿到 Responses 格式的完整回答；原生被记为不可用，后续请求直走映射
  17. dialect-ring  三方言互备环：任意一条方言反复失败都沿环试下一条。
                     17a responses+chat 都坏 → 第三条 anthropic 顶上（responses 入站仍拿到完整回答）；
                     17b chat 坏（responses 好）→ chat 入站被换到 responses 翻译
  18. system-prompt  系统提示归一：chat 入站（system 消息）与 responses 入站（instructions）都必须
                     到达上游（此前只有 anthropic 入站会带上；chat/responses 的系统提示被整个丢掉）
  19. responses-wire  Responses 事件规范字段（严格客户端逐事件 schema 校验，缺字段即整条丢弃）：
                     created_at / item.id / delta.item_id / content_index / done.status / 非流式 output[].id
"""
import json
import os
import re
import shutil
import signal
import socket
import subprocess
import sys
import threading
import time
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))
# 用法：zig build -Doptimize=ReleaseSafe --prefix zig-out/linux && python3 tests/e2e_selfheal.py
# 可用 AUTO_COMPAT_BIN 覆盖被测二进制路径。
BIN = os.environ.get("AUTO_COMPAT_BIN", os.path.join(HERE, "..", "zig-out", "linux", "bin", "auto-compat"))
KEY = "fake-key-123"

STATE = {
    "mode": "path-only",
    "requests": [],          # (method, path, body_dict or None)
    "transient_served": 0,
    "ratelimit_served": 0,
    "slow_first_byte_s": 0.0,  # 场景 11：假上游首字节延迟（秒）
    "headers": [],           # 与研究 requests 平行：每次上游调用收到的凭据头
}


def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def sse_chat(model="fake-model"):
    frames = [
        {"id": "c1", "object": "chat.completion.chunk", "created": 1, "model": model,
         "choices": [{"index": 0, "delta": {"role": "assistant", "content": "ok"}, "finish_reason": None}]},
        {"id": "c1", "object": "chat.completion.chunk", "created": 1, "model": model,
         "choices": [{"index": 0, "delta": {}, "finish_reason": "stop"}],
         "usage": {"prompt_tokens": 1, "completion_tokens": 1, "total_tokens": 2}},
    ]
    body = "".join(f"data: {json.dumps(f)}\n\n" for f in frames) + "data: [DONE]\n\n"
    return body.encode()


def sse_responses(model="fake-model"):
    """OpenAI Responses 事件流（上游适配器的解析口径）。"""
    frames = [
        ("response.created", {"type": "response.created", "response": {"id": "resp_1", "status": "in_progress", "model": model}}),
        ("response.output_item.added", {"type": "response.output_item.added", "output_index": 0,
                                        "item": {"type": "message", "role": "assistant"}}),
        ("response.output_text.delta", {"type": "response.output_text.delta", "output_index": 0, "delta": "ok"}),
        ("response.output_item.done", {"type": "response.output_item.done", "output_index": 0,
                                       "item": {"type": "message", "role": "assistant"}}),
        ("response.completed", {"type": "response.completed", "response": {"id": "resp_1", "status": "completed",
                                                                           "model": model,
                                                                           "usage": {"input_tokens": 1, "output_tokens": 1}}}),
    ]
    return "".join(f"event: {name}\ndata: {json.dumps(payload)}\n\n" for name, payload in frames).encode()


def sse_anthropic(model="fake-model"):
    """Anthropic Messages 事件流（上游适配器的解析口径：message_start → block → delta → stop）。"""
    frames = [
        ("message_start", {"type": "message_start", "message": {"id": "msg_1", "type": "message", "role": "assistant",
                                                               "model": model, "content": [], "stop_reason": None,
                                                               "usage": {"input_tokens": 1, "output_tokens": 0}}}),
        ("content_block_start", {"type": "content_block_start", "index": 0,
                                 "content_block": {"type": "text", "text": ""}}),
        ("content_block_delta", {"type": "content_block_delta", "index": 0,
                                 "delta": {"type": "text_delta", "text": "ok"}}),
        ("content_block_stop", {"type": "content_block_stop", "index": 0}),
        ("message_delta", {"type": "message_delta", "delta": {"stop_reason": "end_turn"},
                           "usage": {"output_tokens": 1}}),
        ("message_stop", {"type": "message_stop"}),
    ]
    return "".join(f"event: {name}\ndata: {json.dumps(payload)}\n\n" for name, payload in frames).encode()


def sse_tools(model="fake-model"):
    """并行双工具调用：交错 index 增量 + finish_reason=tool_calls。"""
    frames = [
        {"id": "c1", "object": "chat.completion.chunk", "created": 1, "model": model,
         "choices": [{"index": 0, "delta": {"role": "assistant", "tool_calls": [
             {"index": 0, "id": "call_1", "type": "function", "function": {"name": "get_weather", "arguments": "{\"city\":"}},
             {"index": 1, "id": "call_2", "type": "function", "function": {"name": "get_time", "arguments": "{\"tz\":"}},
         ]}, "finish_reason": None}]},
        {"id": "c1", "object": "chat.completion.chunk", "created": 1, "model": model,
         "choices": [{"index": 0, "delta": {"tool_calls": [
             {"index": 0, "function": {"arguments": "\"SF\"}"}},
             {"index": 1, "function": {"arguments": "\"UTC\"}"}},
         ]}, "finish_reason": None}]},
        {"id": "c1", "object": "chat.completion.chunk", "created": 1, "model": model,
         "choices": [{"index": 0, "delta": {}, "finish_reason": "tool_calls"}],
         "usage": {"prompt_tokens": 2, "completion_tokens": 3, "total_tokens": 5}},
    ]
    body = "".join(f"data: {json.dumps(f)}\n\n" for f in frames) + "data: [DONE]\n\n"
    return body.encode()


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def _send(self, status, body, ctype="application/json", extra=None):
        self.send_response(status)
        self.send_header("content-type", ctype)
        self.send_header("content-length", str(len(body)))
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(body)

    def _json(self, status, payload, extra=None):
        self._send(status, json.dumps(payload).encode(), extra=extra)

    def _record(self, method, body):
        STATE["requests"].append((method, self.path, body))
        STATE["headers"].append({
            "authorization": self.headers.get("authorization"),
            "x-api-key": self.headers.get("x-api-key"),
        })

    def do_GET(self):
        self._record("GET", None)
        mode = STATE["mode"]
        models = {"object": "list", "data": [{"id": "fake-model", "name": "Fake Model"}]}
        if mode == "path-only":
            if self.path == "/api/v1/models":
                return self._json(200, models)
            return self._json(404, {"error": {"message": "404 page not found"}})
        if mode == "auth":
            return self._json(401, {"error": {"message": "invalid api key"}})
        if self.path in ("/v1/models", "/v1/models/"):
            return self._json(200, models)
        return self._json(404, {"error": {"message": "404 page not found"}})

    def do_POST(self):
        length = int(self.headers.get("content-length") or 0)
        raw = self.rfile.read(length) if length else b""
        try:
            body = json.loads(raw.decode() or "{}")
        except Exception:
            body = {}
        self._record("POST", body)
        mode = STATE["mode"]

        # 场景 15：上游稳定 502（重试耗尽后，客户端必须收到规范失败信号）
        if mode == "always-502":
            return self._json(502, {"error": {"message": "upstream boom"}})

        # 场景 16：厂商 /responses 坏、/chat/completions 正常 → 网关应换方言翻译（原生失败不放弃）
        if mode == "responses-broken" and self.path.endswith("/responses"):
            return self._json(502, {"error": {"message": "responses endpoint broken"}})

        # 场景 17：三方言互备环——/responses 与 /chat/completions 都坏，只剩 /messages 可用
        if mode == "chat-responses-broken" and (self.path.endswith("/responses") or self.path.endswith("chat/completions")):
            return self._json(502, {"error": {"message": "route broken"}})
        if mode == "chat-responses-broken" and self.path.endswith("/messages"):
            return self._send(200, sse_anthropic(), ctype="text/event-stream")

        # 场景 17b：只有 chat 坏（responses 正常）→ chat 入站应被换到 responses
        if mode == "chat-broken" and self.path.endswith("chat/completions"):
            return self._json(502, {"error": {"message": "chat route broken"}})
        if mode == "chat-broken" and self.path.endswith("/responses"):
            return self._send(200, sse_responses(), ctype="text/event-stream")

        chat_paths = {"/v1/chat/completions"}
        if mode == "path-only":
            chat_paths = {"/api/v1/chat/completions"}

        # 探测用的 ping（max_tokens=1 且 messages 里只有 ping）也按正常 chat 处理
        if mode == "auth":
            return self._json(401, {"error": {"message": "invalid api key"}})

        if self.path in chat_paths:
            if mode == "blackhole":
                return  # 永不响应：连接保持打开 → 网关的上游读永久阻塞（由看门狗打断）
            if mode == "slow-first-byte" and STATE["slow_first_byte_s"] > 0:
                time.sleep(STATE["slow_first_byte_s"])
            if mode == "transient":
                STATE["transient_served"] += 1
                if STATE["transient_served"] == 1:
                    return self._json(503, {"error": {"message": "upstream busy"}})
            if mode == "rate-limit":
                STATE["ratelimit_served"] += 1
                if STATE["ratelimit_served"] == 1:
                    return self._json(429, {"error": {"message": "rate limited"}}, extra={"retry-after": "1"})
            if mode == "effort-reject" and body.get("reasoning_effort") is not None:
                return self._json(400, {"error": {
                    "message": "该模型始终思考，不支持关闭思考；请使用 low、high 或 medium",
                    "param": "reasoning_effort",
                }})
            if mode == "tools":
                return self._send(200, sse_tools(), ctype="text/event-stream")
            return self._send(200, sse_chat(), ctype="text/event-stream")

        # 非 chat 路径：/messages、/responses 一律 404（模拟只原生支持 openai 的厂商）
        return self._json(404, {"error": {"message": "404 page not found"}})


def start_fake(port):
    server = ThreadingHTTPServer(("127.0.0.1", port), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    return server


def gateway_env(port, workdir, providers_file="providers.json", extra=None):
    env = dict(os.environ)
    env.update({
        "AUTO_COMPAT_GATEWAY_HOST": "127.0.0.1",
        "AUTO_COMPAT_GATEWAY_PORT": str(port),
        "AUTO_COMPAT_PROVIDERS_FILE": providers_file,
        "AUTO_COMPAT_RETRY_DELAY_MS": "1",
        "FAKE_KEY": KEY,
    })
    if extra:
        env.update(extra)
    return env


def start_gateway(port, workdir, extra_env=None):
    proc = subprocess.Popen(
        [BIN, "serve"],
        cwd=workdir,
        env=gateway_env(port, workdir, extra=extra_env),
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
    )
    # 等就绪（/providers 可答；开了入站鉴权时 401/403 也算"已就绪"）
    for _ in range(200):
        try:
            with urllib.request.urlopen(f"http://127.0.0.1:{port}/providers", timeout=0.5) as resp:
                resp.read()
                return proc
        except urllib.error.HTTPError as err:
            if err.code in (401, 403):
                return proc
        except Exception:
            pass
        if proc.poll() is not None:
            raise RuntimeError("gateway exited early:\n" + proc.stdout.read())
        time.sleep(0.1)
    raise RuntimeError("gateway not ready")


def stop(proc):
    try:
        proc.send_signal(signal.SIGKILL)
        proc.wait(timeout=5)
    except Exception:
        pass


def run_brief(workdir, extra_env, args=None, seconds=1.2):
    """短跑一个 CLI 进程（到点杀掉），返回合并输出——只关心启动日志的检查用。"""
    env = dict(os.environ)
    env.pop("AUTO_COMPAT_MENU", None)
    env.update(extra_env)
    proc = subprocess.Popen(
        [BIN, *(args if args is not None else ["serve"])],
        cwd=workdir, env=env, stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
    )
    try:
        out, _ = proc.communicate(timeout=seconds)
    except subprocess.TimeoutExpired:
        proc.kill()
        out, _ = proc.communicate(timeout=5)
    return out or ""


def gateway_log(proc):
    """进程结束后读取其 stdout+stderr（启动日志/自愈留痕都在这里）。"""
    try:
        return proc.stdout.read() or ""
    except Exception:
        return ""


def post(port, path, payload, headers=None):
    merged = {"content-type": "application/json"}
    if headers:
        merged.update(headers)
    req = urllib.request.Request(
        f"http://127.0.0.1:{port}{path}",
        data=json.dumps(payload).encode(),
        headers=merged,
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            return resp.status, resp.read().decode()
    except urllib.error.HTTPError as err:
        return err.code, err.read().decode()


def post_stream(port, path, payload, headers=None):
    """逐行读 SSE 并记录每行到达时间：验证"帧确实在静默期到达客户端"（不止字节顺序）。"""
    merged = {"content-type": "application/json"}
    if headers:
        merged.update(headers)
    req = urllib.request.Request(
        f"http://127.0.0.1:{port}{path}",
        data=json.dumps(payload).encode(),
        headers=merged,
        method="POST",
    )
    started = time.monotonic()
    lines = []
    with urllib.request.urlopen(req, timeout=60) as resp:
        status = resp.status
        header_at = time.monotonic() - started
        while True:
            raw = resp.readline()
            if not raw:
                break
            lines.append((time.monotonic() - started, raw.decode()))
    return status, header_at, lines


def write_providers(workdir, entries):
    with open(os.path.join(workdir, "providers.json"), "w") as fh:
        json.dump(entries, fh)


def clear_requests():
    STATE["requests"] = []
    STATE["headers"] = []
    STATE["transient_served"] = 0
    STATE["ratelimit_served"] = 0


def chat_paths_in_log():
    return [path for (method, path, _body) in STATE["requests"] if path.endswith("chat/completions")]


def post_paths_in_log():
    return [path for (method, path, _body) in STATE["requests"] if method == "POST"]


def effort_seen():
    return [bool(body and body.get("reasoning_effort") is not None) for (_m, p, body) in STATE["requests"] if p.endswith("chat/completions")]


FAILURES = []


def check(name, cond, detail=""):
    status = "PASS" if cond else "FAIL"
    print(f"  [{status}] {name}" + (f" — {detail}" if detail and not cond else ""))
    if not cond:
        FAILURES.append(name)


def scenario(name, mode):
    workdir = f"/tmp/e2e-{name}"
    shutil.rmtree(workdir, ignore_errors=True)
    os.makedirs(workdir, exist_ok=True)
    STATE["mode"] = mode
    clear_requests()
    return workdir


def main():
    results = {}

    # ---------------- 版本号可见性（用户辨别新旧二进制的唯一入口） ----------------
    help_run = subprocess.run([BIN, "help"], capture_output=True, text=True, timeout=30)
    check("help 输出版本号（0.x）",
          re.search(r"auto-compat 0\.\d+\.\d+", help_run.stdout or "") is not None,
          f"stdout_head={(help_run.stdout or '')[:120]}")
    version_run = subprocess.run([BIN, "--version"], capture_output=True, text=True, timeout=30)
    check("--version 干净输出且 exit 0",
          version_run.returncode == 0
          and re.fullmatch(r"auto-compat 0\.\d+\.\d+\n?", version_run.stdout or "") is not None
          and (version_run.stderr or "") == "",
          f"rc={version_run.returncode} out={version_run.stdout!r} err={version_run.stderr!r}")

    # ---------------- 场景 1：运行时后缀发现（裸站点，启动时上游不可达） ----------------
    print("场景 1: 裸站点 → 运行时发现 /api/v1")
    workdir = scenario("pathonly", "path-only")
    fake_port = free_port()
    gw_port = free_port()
    write_providers(workdir, [{"name": "fake", "baseURL": f"http://127.0.0.1:{fake_port}",
                               "apiKeyEnv": "FAKE_KEY", "protocol": "openai"}])
    gw = start_gateway(gw_port, workdir)          # 假上游未起 → 装载期发现失败
    fake = start_fake(fake_port)
    try:
        status, body = post(gw_port, "/v1/chat/completions",
                            {"model": "fake/fake-model", "max_tokens": 16,
                             "messages": [{"role": "user", "content": "hi"}]})
        check("首次请求经运行时发现成功 200", status == 200, f"status={status} body={body[:200]}")
        check("上游命中 /api/v1/chat/completions", "/api/v1/chat/completions" in chat_paths_in_log(), f"log={chat_paths_in_log()}")
        log_after_first = len(STATE["requests"])
        clear_requests()
        status2, _ = post(gw_port, "/v1/chat/completions",
                          {"model": "fake/fake-model", "max_tokens": 16,
                           "messages": [{"role": "user", "content": "hi again"}]})
        check("第二次请求 200", status2 == 200, f"status={status2}")
        check("第二次直连固定路径（1 次上游调用）", len(chat_paths_in_log()) == 1, f"log={chat_paths_in_log()}")
        with open(os.path.join(workdir, "providers.json")) as fh:
            persisted = json.load(fh)
        entry = [e for e in persisted if e.get("name") == "fake"][0]
        check("providers.json 写回固定路径", entry.get("baseURL", "").endswith("/api/v1"), f"entry={entry}")
        results["path-only"] = len(FAILURES) == 0
    finally:
        stop(gw)
        fake.shutdown()

    # ---------------- 场景 2：方言映射（只原生 openai） ----------------
    print("场景 2: anthropic 入站 → 原生 /messages 404 → 映射 openai")
    workdir = scenario("mapping", "openai-only")
    fake_port = free_port()
    gw_port = free_port()
    write_providers(workdir, [{"name": "fake", "baseURL": f"http://127.0.0.1:{fake_port}/v1",
                               "apiKeyEnv": "FAKE_KEY", "protocol": "openai"}])
    fake = start_fake(fake_port)
    gw = start_gateway(gw_port, workdir)
    try:
        clear_requests()
        status, body = post(gw_port, "/v1/messages",
                            {"model": "fake/fake-model", "max_tokens": 16,
                             "messages": [{"role": "user", "content": "hi"}]})
        check("anthropic 入站最终 200（映射后）", status == 200, f"status={status} body={body[:200]}")
        try:
            parsed = json.loads(body)
            check("响应是 anthropic 形状", parsed.get("type") == "message", f"body={body[:200]}")
        except Exception as exc:
            check("响应是 anthropic 形状", False, f"{exc}")
        paths = post_paths_in_log()
        check("先试原生 /v1/messages（404）再走 /v1/chat/completions",
              paths == ["/v1/messages", "/v1/chat/completions"], f"log={paths}")
        clear_requests()
        status2, _ = post(gw_port, "/v1/messages",
                          {"model": "fake/fake-model", "max_tokens": 16,
                           "messages": [{"role": "user", "content": "again"}]})
        check("第二次 anthropic 入站 200", status2 == 200, f"status={status2}")
        paths2 = chat_paths_in_log()
        check("第二次直接走映射（不再试 /v1/messages）", paths2 == ["/v1/chat/completions"], f"log={paths2}")
        results["mapping"] = len(FAILURES) == 0
    finally:
        stop(gw)
        fake.shutdown()

    # ---------------- 场景 3：档位自适应 ----------------
    print("场景 3: 上游拒绝 reasoning_effort → 省略重试并记住")
    workdir = scenario("effort", "effort-reject")
    fake_port = free_port()
    gw_port = free_port()
    write_providers(workdir, [{"name": "fake", "baseURL": f"http://127.0.0.1:{fake_port}/v1",
                               "apiKeyEnv": "FAKE_KEY", "protocol": "openai", "preset": "intern-ai"}])
    fake = start_fake(fake_port)
    gw = start_gateway(gw_port, workdir)
    try:
        clear_requests()
        status, body = post(gw_port, "/v1/chat/completions",
                            {"model": "fake/fake-model", "reasoning_effort": "off", "max_tokens": 16,
                             "messages": [{"role": "user", "content": "hi"}]})
        check("带档位请求最终 200（省略后）", status == 200, f"status={status} body={body[:200]}")
        seen = effort_seen()
        check("第一次带档位被拒、第二次不带档位", seen == [True, False], f"effort_seen={seen}")
        clear_requests()
        status2, _ = post(gw_port, "/v1/chat/completions",
                          {"model": "fake/fake-model", "reasoning_effort": "off", "max_tokens": 16,
                           "messages": [{"role": "user", "content": "again"}]})
        seen2 = effort_seen()
        check("第二次 200", status2 == 200, f"status={status2}")
        check("记住适配：第三次请求只发 1 次且不带档位", seen2 == [False], f"effort_seen={seen2}")
        results["effort"] = len(FAILURES) == 0
    finally:
        stop(gw)
        fake.shutdown()

    # ---------------- 场景 4：瞬态 5xx 退避重试 ----------------
    print("场景 4: 首次 503、二次 200 → 退避重试")
    workdir = scenario("transient", "transient")
    fake_port = free_port()
    gw_port = free_port()
    write_providers(workdir, [{"name": "fake", "baseURL": f"http://127.0.0.1:{fake_port}/v1",
                               "apiKeyEnv": "FAKE_KEY", "protocol": "openai"}])
    fake = start_fake(fake_port)
    gw = start_gateway(gw_port, workdir)
    try:
        clear_requests()
        status, _ = post(gw_port, "/v1/chat/completions",
                         {"model": "fake/fake-model", "max_tokens": 16,
                          "messages": [{"role": "user", "content": "hi"}]})
        check("客户端拿到 200（瞬态被内部消化）", status == 200, f"status={status}")
        check("上游被调用 2 次", len(chat_paths_in_log()) == 2, f"log={chat_paths_in_log()}")
        results["transient"] = len(FAILURES) == 0
    finally:
        stop(gw)
        fake.shutdown()

    # ---------------- 场景 5：429 + Retry-After ----------------
    print("场景 5: 429 + Retry-After → 等待后重试")
    workdir = scenario("ratelimit", "rate-limit")
    fake_port = free_port()
    gw_port = free_port()
    write_providers(workdir, [{"name": "fake", "baseURL": f"http://127.0.0.1:{fake_port}/v1",
                               "apiKeyEnv": "FAKE_KEY", "protocol": "openai"}])
    fake = start_fake(fake_port)
    gw = start_gateway(gw_port, workdir)
    try:
        clear_requests()
        started = time.time()
        status, _ = post(gw_port, "/v1/chat/completions",
                         {"model": "fake/fake-model", "max_tokens": 16,
                          "messages": [{"role": "user", "content": "hi"}]})
        elapsed = time.time() - started
        check("客户端拿到 200", status == 200, f"status={status}")
        check("等待了 Retry-After（≥1s）", elapsed >= 1.0, f"elapsed={elapsed:.2f}s")
        check("上游被调用 2 次", len(chat_paths_in_log()) == 2, f"log={chat_paths_in_log()}")
        results["ratelimit"] = len(FAILURES) == 0
    finally:
        stop(gw)
        fake.shutdown()

    # ---------------- 场景 6：401 不重试 ----------------
    print("场景 6: 401 → 不重试，AUTH 原样上抛")
    workdir = scenario("auth", "auth")
    fake_port = free_port()
    gw_port = free_port()
    write_providers(workdir, [{"name": "fake", "baseURL": f"http://127.0.0.1:{fake_port}/v1",
                               "apiKeyEnv": "FAKE_KEY", "protocol": "openai"}])
    fake = start_fake(fake_port)
    gw = start_gateway(gw_port, workdir)
    try:
        clear_requests()
        status, body = post(gw_port, "/v1/chat/completions",
                            {"model": "fake/fake-model", "max_tokens": 16,
                             "messages": [{"role": "user", "content": "hi"}]})
        check("客户端拿到 502（网关信封）", status == 502, f"status={status}")
        check("信封 code=AUTH", "AUTH" in body, f"body={body[:200]}")
        check("上游只被调用 1 次（不重试）", len(chat_paths_in_log()) == 1, f"log={chat_paths_in_log()}")
        results["auth"] = len(FAILURES) == 0
    finally:
        stop(gw)
        fake.shutdown()

    # ---------------- 场景 7：写回后重启，直连固定路径 ----------------
    print("场景 7: 重启后直连写回的成功路径（openai 入站，不含探测）")
    workdir = scenario("persist", "openai-only")
    fake_port = free_port()
    gw_port = free_port()
    write_providers(workdir, [{"name": "fake", "baseURL": f"http://127.0.0.1:{fake_port}/v1",
                               "apiKeyEnv": "FAKE_KEY", "protocol": "openai"}])
    fake = start_fake(fake_port)
    gw = start_gateway(gw_port, workdir)
    try:
        clear_requests()
        status, _ = post(gw_port, "/v1/chat/completions",
                         {"model": "fake/fake-model", "max_tokens": 16,
                          "messages": [{"role": "user", "content": "hi"}]})
        check("首次 200", status == 200, f"status={status}")
    finally:
        stop(gw)
    try:
        with open(os.path.join(workdir, "providers.json")) as fh:
            persisted = json.load(fh)
        check("providers.json 含写回的 fake 条目",
              any(e.get("name") == "fake" and e.get("baseURL", "").endswith("/v1") for e in persisted),
              f"persisted={persisted}")
    except Exception as exc:
        check("providers.json 含写回的 fake 条目", False, str(exc))

    gw2 = start_gateway(gw_port, workdir)
    try:
        clear_requests()
        status2, _ = post(gw_port, "/v1/chat/completions",
                          {"model": "fake/fake-model", "max_tokens": 16,
                           "messages": [{"role": "user", "content": "after restart"}]})
        check("重启后 200", status2 == 200, f"status={status2}")
        paths = chat_paths_in_log()
        check("重启后首次请求直连固定路径（1 次 chat 调用）", len(paths) == 1, f"log={paths}")
        results["persist"] = len(FAILURES) == 0
    finally:
        stop(gw2)
        fake.shutdown()

    # ---------------- 场景 8：并行双工具 → Responses done 全字段 ----------------
    print("场景 8: 并行双工具 → Responses item added/done 带全字段、各占一个 output_index")
    workdir = scenario("tools", "tools")
    fake_port = free_port()
    gw_port = free_port()
    write_providers(workdir, [{"name": "fake", "baseURL": f"http://127.0.0.1:{fake_port}/v1",
                               "apiKeyEnv": "FAKE_KEY", "protocol": "openai"}])
    fake = start_fake(fake_port)
    gw = start_gateway(gw_port, workdir)
    try:
        clear_requests()
        status, body = post(gw_port, "/v1/responses",
                            {"model": "fake/fake-model", "stream": True, "input": "北京和东京的天气/时间？",
                             "tools": [{"type": "function", "name": "get_weather", "parameters": {"type": "object"}}]})
        check("SSE 200", status == 200, f"status={status} body={body[:200]}")
        added_events = re.findall(r"event: response\.output_item\.added\ndata: (\{[^\n]*\})", body)
        done_events = re.findall(r"event: response\.output_item\.done\ndata: (\{[^\n]*\})", body)
        added = [json.loads(e) for e in added_events]
        done = [json.loads(e) for e in done_events]
        added_items = {e["item"].get("id"): e["item"] for e in added if e["item"].get("type") == "function_call"}
        done_items = {e["item"].get("id"): e["item"] for e in done if e["item"].get("type") == "function_call"}
        check("两个 function_call added（各带 id/name）",
              set(added_items) == {"call_1", "call_2"}
              and added_items["call_1"].get("name") == "get_weather"
              and added_items["call_2"].get("name") == "get_time",
              f"added={added_items}")
        check("两个 done 带完整 id/name/arguments",
              set(done_items) == {"call_1", "call_2"}
              and done_items["call_1"].get("arguments") == "{\"city\":\"SF\"}"
              and done_items["call_2"].get("arguments") == "{\"tz\":\"UTC\"}"
              and done_items["call_1"].get("name") == "get_weather"
              and done_items["call_2"].get("name") == "get_time",
              f"done={done_items}")
        done_indexes = sorted(e["output_index"] for e in done if e["item"].get("type") == "function_call")
        check("并行工具各占一个 output_index（0/1）", done_indexes == [0, 1], f"indexes={done_indexes}")
        check("completed 事件存在", "response.completed" in body)
        # 上游收到的是翻译后的 openai 方言请求（含 tools 与 stream）
        upstream_posts = [b for (m, p, b) in STATE["requests"] if m == "POST" and p.endswith("chat/completions")]
        check("上游命中 /chat/completions 且带 tools",
              len(upstream_posts) == 1 and "tools" in (upstream_posts[0] or {}),
              f"upstream={upstream_posts}")
        results["tools"] = len(FAILURES) == 0
    finally:
        stop(gw)
        fake.shutdown()

    # ---------------- 场景 9：歧义治理（装载期同端点去重 + 可行动 400） ----------------
    print("场景 9a: providers.json 同端点条目 → 装载期忽略（内置优先），日志讲清楚")
    workdir = scenario("dedup", "openai-only")
    gw_port = free_port()
    # custom-1 与内置 intern-ai 端点完全相同（探针 --url 指向内置厂商时的典型产物）
    write_providers(workdir, [{"name": "custom-1",
                               "baseURL": "https://discovery-api.intern-ai.org.cn/v1",
                               "apiKeyEnv": "CUSTOM_KEY"}])
    gw = start_gateway(gw_port, workdir)   # 早判短路：装载期不触网
    try:
        with urllib.request.urlopen(f"http://127.0.0.1:{gw_port}/providers", timeout=5) as resp:
            listed = json.loads(resp.read())
        ids = [entry.get("id") for entry in listed.get("data", [])]
        check("同端点条目未注册（仍只有两家内置，裸模型 id 不会歧义）",
              ids == ["intern-ai", "amd-radeon"], f"ids={ids}")
        # 自描述显式说明等待/超时限制（默认 600s 空闲超时 / 55s 占位），机器可读
        with urllib.request.urlopen(f"http://127.0.0.1:{gw_port}/", timeout=5) as resp:
            described = json.loads(resp.read())
        limits = described.get("limits", {})
        check("GET / 显式给出 limits（空闲超时默认 600000、占位 55000）",
              limits.get("upstreamIdleTimeoutMs") == 600000 and limits.get("upstreamIdleTimeoutEnabled") is True
              and limits.get("placeholderKeepaliveMs") == 55000 and limits.get("placeholderEnabled") is True,
              f"limits={limits}")
    finally:
        stop(gw)
        log = gateway_log(gw)
    check("日志说明归并（同端点=同一供应商、内置优先、条目被忽略；ASCII 防乱码）",
          "custom-1" in log and "intern-ai" in log and "same endpoint" in log and 'built-in "intern-ai"' in log
          and "ignoring the entry" in log and "will NOT apply" in log,
          f"log_tail={log[-300:]}")
    results["dedup"] = len(FAILURES) == 0

    print("场景 9b: 两个供应商都有 fake-model → 裸 id 400 列出候选并给出写法")
    workdir = scenario("ambiguous", "openai-only")
    fake_a_port = free_port()
    fake_b_port = free_port()
    gw_port = free_port()
    write_providers(workdir, [
        {"name": "fake-a", "baseURL": f"http://127.0.0.1:{fake_a_port}/v1", "apiKeyEnv": "FAKE_KEY", "protocol": "openai"},
        {"name": "fake-b", "baseURL": f"http://127.0.0.1:{fake_b_port}/v1", "apiKeyEnv": "FAKE_KEY", "protocol": "openai"},
    ])
    fake_a = start_fake(fake_a_port)
    fake_b = start_fake(fake_b_port)
    gw = start_gateway(gw_port, workdir)
    try:
        status, body = post(gw_port, "/v1/chat/completions",
                            {"model": "fake-model", "max_tokens": 16,
                             "messages": [{"role": "user", "content": "hi"}]})
        check("裸模型 id 得到 400", status == 400, f"status={status} body={body[:200]}")
        try:
            parsed = json.loads(body)
            error = parsed.get("error", {})
            message = error.get("message", "")
        except Exception as exc:
            error, message = {}, f"parse-error: {exc}"
        check("code=AMBIGUOUS_MODEL", error.get("code") == "AMBIGUOUS_MODEL", f"error={error}")
        check("消息列出候选供应商",
              "fake-model" in message and "fake-a" in message and "fake-b" in message and "exists in:" in message,
              f"message={message}")
        check("消息给出 provider/model 写法建议",
              '"fake-a/fake-model"' in message and '"fake-b/fake-model"' in message and 'use "provider/model"' in message,
              f"message={message}")

        clear_requests()
        status2, body2 = post(gw_port, "/v1/chat/completions",
                              {"model": "fake-a/fake-model", "max_tokens": 16,
                               "messages": [{"role": "user", "content": "hi"}]})
        check("按建议写 provider/model 即 200", status2 == 200, f"status={status2} body={body2[:200]}")
        results["ambiguity"] = len(FAILURES) == 0
    finally:
        stop(gw)
        fake_a.shutdown()
        fake_b.shutdown()

    print("场景 9c: 裸站点解析后与已注册端点相同 → 复核去重（先注册者优先）")
    workdir = scenario("dedup2", "openai-only")
    fake_port = free_port()
    gw_port = free_port()
    write_providers(workdir, [
        {"name": "fake-a", "baseURL": f"http://127.0.0.1:{fake_port}/v1", "apiKeyEnv": "FAKE_KEY", "protocol": "openai"},
        {"name": "fake-b", "baseURL": f"http://127.0.0.1:{fake_port}", "apiKeyEnv": "FAKE_KEY", "protocol": "openai"},
    ])
    fake = start_fake(fake_port)
    gw = start_gateway(gw_port, workdir)
    try:
        with urllib.request.urlopen(f"http://127.0.0.1:{gw_port}/providers", timeout=5) as resp:
            listed = json.loads(resp.read())
        ids = [entry.get("id") for entry in listed.get("data", [])]
        check("fake-b 的裸站点解析到 /v1（= fake-a）→ 未注册第二个供应商",
              ids == ["intern-ai", "amd-radeon", "fake-a"], f"ids={ids}")
    finally:
        stop(gw)
        log = gateway_log(gw)
        fake.shutdown()
    check("日志说明先注册者优先（fake-b 被忽略）",
          "fake-b" in log and "fake-a" in log and "same endpoint" in log and 'earlier-registered "fake-a"' in log,
          f"log_tail={log[-300:]}")
    results["dedup-resolved"] = len(FAILURES) == 0

    # ---------------- 场景 10：探针命中即停 ----------------
    print("场景 10: probe 命中用户 URL 即停（不再轮询其余 7 个预设端点），同端点只固化一条")
    workdir = scenario("probe-exit", "openai-only")
    fake_port = free_port()
    write_providers(workdir, [])  # 探针输出走独立文件，不与网关装载混用
    fake = start_fake(fake_port)
    try:
        out_path = os.path.join(workdir, "frozen.json")
        started = time.time()
        proc = subprocess.run(
            [BIN, "probe", "--key-env", "FAKE_KEY",
             "--url", f"http://127.0.0.1:{fake_port}",
             "--url", f"http://127.0.0.1:{fake_port}/v1",
             "--out", out_path, "--verify-models", "2"],
            cwd=workdir, env=gateway_env(fake_port, workdir),
            capture_output=True, text=True, timeout=120,
        )
        elapsed = time.time() - started
        check("probe 退出码 0", proc.returncode == 0, f"rc={proc.returncode} out={(proc.stdout + proc.stderr)[-300:]}")
        check("命中即停（<60s；旧行为要轮询 7 个真实预设端点，远超此限）", elapsed < 60, f"elapsed={elapsed:.1f}s")
        with open(out_path) as fh:
            frozen = json.load(fh)
        check("两个 --url 解析到同一端点 → 只固化 1 条 custom-1（/v1）",
              len(frozen) == 1 and frozen[0].get("name") == "custom-1"
              and str(frozen[0].get("baseURL", "")).endswith("/v1"),
              f"frozen={frozen}")
        results["probe-exit"] = len(FAILURES) == 0
    finally:
        fake.shutdown()

    # ---------------- 场景 11：占位保活（静默注入 + 上游剥离） ----------------
    print("场景 11: 上游静默 → 占位注入客户端；回灌历史 → 上游无占位、裸省略号保留")
    PLACEHOLDER = "\u2063\u2026\u2063"
    workdir = scenario("placeholder", "slow-first-byte")
    fake_port = free_port()
    gw_port = free_port()
    STATE["slow_first_byte_s"] = 2.0
    write_providers(workdir, [{"name": "fake", "baseURL": f"http://127.0.0.1:{fake_port}/v1",
                               "apiKeyEnv": "FAKE_KEY", "protocol": "openai"}])
    fake = start_fake(fake_port)
    gw = start_gateway(gw_port, workdir, extra_env={"AUTO_COMPAT_PLACEHOLDER_MS": "600"})
    try:
        clear_requests()
        status, header_at, streamed = post_stream(gw_port, "/v1/chat/completions",
                                       {"model": "fake/fake-model", "stream": True, "max_tokens": 16,
                                        "messages": [{"role": "user", "content": "hi"}]})
        body = "".join(line for _at, line in streamed)
        elapsed = streamed[-1][0] if streamed else 0.0
        check("客户端最终拿到完整 SSE", status == 200 and "data: [DONE]" in body, f"status={status}")
        check("响应头在上游静默期内就到达（<1s，不等首帧）", header_at < 1.0, f"header_at={header_at:.2f}s")
        check("静默期间注入了占位（隐形哨兵包裹的省略号）", PLACEHOLDER in body, f"body_head={body[:300]}")
        check("占位在真实内容之前到达", PLACEHOLDER in body and body.index(PLACEHOLDER) < body.index("ok"),
              f"placeholder_at={body.find(PLACEHOLDER)} ok_at={body.find('ok')}")
        placeholder_times = [at for at, line in streamed if line.startswith("data: ") and PLACEHOLDER in line]
        real_times = [at for at, line in streamed
                      if line.startswith("data: ") and '"ok"' in line and '"delta"' in line]
        check("占位在静默期真正到达客户端（<1.5s，而不是响应结束后才一起到达）",
              bool(placeholder_times) and placeholder_times[0] < 1.5,
              f"first_placeholder_at={placeholder_times[0] if placeholder_times else None}")
        check("真实内容到达前客户端已收到保活（占位领先 ≥0.5s）",
              bool(placeholder_times) and bool(real_times) and placeholder_times[0] < real_times[0] - 0.5,
              f"placeholder_at={placeholder_times[:1]} real_at={real_times[:1]}")
        placeholder_frames = [line for line in body.splitlines()
                              if line.startswith("data: ") and PLACEHOLDER in line]
        valid = True
        try:
            for line in placeholder_frames:
                parsed = json.loads(line[len("data: "):])
                delta = parsed["choices"][0]["delta"]
                valid = valid and delta.get("content") == PLACEHOLDER
        except Exception:
            valid = False
        check("占位是合法 JSON 内容增量（choices[0].delta.content）", valid, f"frames={placeholder_frames[:2]}")
        check("慢上游（2s）被完整等待", elapsed >= 2.0, f"elapsed={elapsed:.2f}s")

        # 回灌：把占位原样放进下一轮 assistant 历史；另一句带裸省略号必须原样保留
        clear_requests()
        status2, _ = post(gw_port, "/v1/chat/completions",
                          {"model": "fake/fake-model", "max_tokens": 16,
                           "messages": [
                               {"role": "user", "content": "hi"},
                               {"role": "assistant", "content": PLACEHOLDER + "ok，等等\u2026好的"},
                               {"role": "user", "content": "继续"}]})
        upstream_posts = [b for (m, p, b) in STATE["requests"] if m == "POST" and p.endswith("chat/completions")]
        check("回灌请求到达上游", status2 == 200 and len(upstream_posts) == 1, f"status={status2} posts={len(upstream_posts)}")
        forwarded = json.dumps(upstream_posts[0], ensure_ascii=False) if upstream_posts else ""
        check("上游收到的请求体无哨兵/占位（token 不浪费）",
              "\u2063" not in forwarded and PLACEHOLDER not in forwarded, f"forwarded={forwarded[:200]}")
        check("裸省略号与真实文本原样保留",
              "等等\u2026好的" in forwarded and "ok，等等" in forwarded, f"forwarded={forwarded[:200]}")
        check("回灌后消息条数不变（3 条，结构不动）",
              upstream_posts and len(upstream_posts[0].get("messages", [])) == 3,
              f"messages={upstream_posts[0].get('messages') if upstream_posts else None}")
        results["placeholder"] = len(FAILURES) == 0
    finally:
        stop(gw)
        log = gateway_log(gw)
        fake.shutdown()
    check("网关日志注明占位注入", "placeholder keepalive: injected" in log, f"log_tail={log[-300:]}")

    # ---------------- 场景 12：黑洞上游 → 空闲超时有界失败 ----------------
    print("场景 12: 上游 accept 后永不响应 → 看门狗打断 → TIMEOUT 有界失败（网关不挂死）")
    workdir = scenario("blackhole", "blackhole")
    fake_port = free_port()
    gw_port = free_port()
    write_providers(workdir, [{"name": "fake", "baseURL": f"http://127.0.0.1:{fake_port}/v1",
                               "apiKeyEnv": "FAKE_KEY", "protocol": "openai"}])
    fake = start_fake(fake_port)
    gw = start_gateway(gw_port, workdir, extra_env={"AUTO_COMPAT_IDLE_TIMEOUT_MS": "800"})
    try:
        clear_requests()
        # 非流式：3 次尝试（800ms 空闲 + 快档退避）后以 502 信封上抛，code=TIMEOUT
        started = time.time()
        status, body = post(gw_port, "/v1/chat/completions",
                            {"model": "fake/fake-model", "max_tokens": 16,
                             "messages": [{"role": "user", "content": "hi"}]})
        elapsed = time.time() - started
        check("非流式有界失败（502 信封，报告 TIMEOUT 而非回退探测的 404）",
              status == 502 and '"code":"TIMEOUT"' in body, f"status={status} body={body[:200]}")
        check("失败发生在毫秒级空闲超时的量级（<15s）", elapsed < 15, f"elapsed={elapsed:.2f}s")
        check("重试确实发生（chat ≥3 次；之后沿三方言环继续试）", len(chat_paths_in_log()) >= 3, f"log={chat_paths_in_log()}")

        # 流式：客户端拿到 error 帧 + [DONE]（而不是永久挂起）
        clear_requests()
        started = time.time()
        status2, body2 = post(gw_port, "/v1/chat/completions",
                              {"model": "fake/fake-model", "stream": True, "max_tokens": 16,
                               "messages": [{"role": "user", "content": "hi"}]})
        elapsed2 = time.time() - started
        check("流式有界失败（error 帧 + [DONE]）",
              status2 == 200 and '"code":"TIMEOUT"' in body2 and "data: [DONE]" in body2,
              f"status={status2} body={body2[:200]}")
        check("流式失败同样有界（<15s）", elapsed2 < 15, f"elapsed={elapsed2:.2f}s")

        # 网关未挂死：换回正常模式后请求立刻成功
        STATE["mode"] = "openai-only"
        clear_requests()
        status3, _ = post(gw_port, "/v1/chat/completions",
                          {"model": "fake/fake-model", "max_tokens": 16,
                           "messages": [{"role": "user", "content": "hi"}]})
        check("黑洞过后网关仍可服务（200）", status3 == 200, f"status={status3}")
        results["blackhole"] = len(FAILURES) == 0
    finally:
        stop(gw)
        log = gateway_log(gw)
        fake.shutdown()
    check("网关日志注明空闲超时打断", "upstream idle timeout" in log, f"log_tail={log[-300:]}")

    # ---------------- 场景 13：入站 key 直通上游（key 中转） ----------------
    print("场景 13: 无环境变量时，入站携带的 api-key 直通上游；环境变量优先；网关令牌不外传")
    workdir = scenario("clientkey", "openai-only")
    fake_port = free_port()
    gw_port = free_port()
    STATE["slow_first_byte_s"] = 0.0
    # 条目指向一个未设置的环境变量名 → 网关没有 env key，只能靠入站携带
    write_providers(workdir, [{"name": "fake", "baseURL": f"http://127.0.0.1:{fake_port}/v1",
                               "apiKeyEnv": "FAKE_UNSET_KEY", "protocol": "openai"}])
    fake = start_fake(fake_port)
    gw = start_gateway(gw_port, workdir)
    try:
        # (a) x-api-key（Anthropic 客户端风格，即 dsh 供应商 UI 的用法）→ 直通
        clear_requests()
        status, body = post(gw_port, "/v1/messages",
                            {"model": "fake/fake-model", "max_tokens": 16,
                             "messages": [{"role": "user", "content": "hi"}]},
                            headers={"x-api-key": "sk-client-abc"})
        check("anthropic 入站 + x-api-key 直通 → 200", status == 200, f"status={status} body={body[:200]}")
        chat_auths = [h["authorization"] for (m, p, _b), h in zip(STATE["requests"], STATE["headers"])
                      if p.endswith("chat/completions")]
        check("上游收到客户端 key（Bearer sk-client-abc）",
              chat_auths == ["Bearer sk-client-abc"], f"auths={chat_auths}")
        check("上游同时收到 x-api-key 形式的 key",
              any(h["x-api-key"] == "sk-client-abc" for h in STATE["headers"]), f"headers={STATE['headers'][:3]}")

        # (b) Authorization: Bearer（OpenAI 客户端风格）→ 直通
        clear_requests()
        status2, _ = post(gw_port, "/v1/chat/completions",
                          {"model": "fake/fake-model", "max_tokens": 16,
                           "messages": [{"role": "user", "content": "hi"}]},
                          headers={"authorization": "Bearer sk-client-bearer"})
        bearer_auths = [h["authorization"] for h in STATE["headers"] if h["authorization"]]
        check("chat 入站 + Authorization Bearer 直通 → 200", status2 == 200, f"status={status2}")
        check("上游收到 Bearer sk-client-bearer", bearer_auths == ["Bearer sk-client-bearer"], f"auths={bearer_auths}")

        # (c) 环境变量优先：条目用已设置的 FAKE_KEY，客户端另带一个 key → 上游应看到 env 的那个
        stop(gw)
        log_passthrough = gateway_log(gw)   # a/b 两台（直通）的日志先取走
        write_providers(workdir, [{"name": "fake", "baseURL": f"http://127.0.0.1:{fake_port}/v1",
                                   "apiKeyEnv": "FAKE_KEY", "protocol": "openai"}])
        gw = start_gateway(gw_port, workdir)
        clear_requests()
        status3, _ = post(gw_port, "/v1/chat/completions",
                          {"model": "fake/fake-model", "max_tokens": 16,
                           "messages": [{"role": "user", "content": "hi"}]},
                          headers={"x-api-key": "sk-client-loses"})
        env_auths = [h["authorization"] for h in STATE["headers"] if h["authorization"]]
        check("环境变量优先：上游看到 env key 而不是客户端 key",
              status3 == 200 and env_auths == [f"Bearer {KEY}"], f"status={status3} auths={env_auths}")
    finally:
        stop(gw)
        fake.shutdown()
    check("日志注明正在中转入站 key（直通实例）",
          "forwarding the inbound client API key upstream" in log_passthrough, f"log_tail={log_passthrough[-300:]}")

    # (d) 网关令牌不外传：带网关 token 的 Authorization 不会被当上游 key；无 key → MISSING_CREDENTIAL 快失败
    print("场景 13d: 网关令牌不外传 + 无 key 快失败（MISSING_CREDENTIAL，不重试）")
    workdir = scenario("clientkey-token", "openai-only")
    fake_port = free_port()
    gw_port = free_port()
    write_providers(workdir, [{"name": "fake", "baseURL": f"http://127.0.0.1:{fake_port}/v1",
                               "apiKeyEnv": "FAKE_UNSET_KEY", "protocol": "openai"}])
    fake = start_fake(fake_port)
    gw = start_gateway(gw_port, workdir, extra_env={"AUTO_COMPAT_GATEWAY_TOKEN": "tok123"})
    try:
        clear_requests()
        status, body = post(gw_port, "/v1/chat/completions",
                            {"model": "fake/fake-model", "max_tokens": 16,
                             "messages": [{"role": "user", "content": "hi"}]},
                            headers={"authorization": "Bearer tok123"})
        check("网关令牌被拒绝当上游 key → 502 code=MISSING_CREDENTIAL",
              status == 502 and "MISSING_CREDENTIAL" in body, f"status={status} body={body[:200]}")
        check("快失败：上游一次都没被调用（不重试）", len(chat_paths_in_log()) == 0, f"log={chat_paths_in_log()}")
        check("提示里给出两条补救路径（export env 或随请求带 key）",
              "export FAKE_UNSET_KEY" in body and "x-api-key" in body, f"body={body[:300]}")

        # 鉴权载体：Anthropic 标准客户端只发 x-api-key
        status_x, _ = post(gw_port, "/v1/chat/completions",
                           {"model": "fake/fake-model", "max_tokens": 16,
                            "messages": [{"role": "user", "content": "hi"}]},
                           headers={"x-api-key": "tok123"})
        check("网关令牌用 x-api-key 载体也能通过鉴权（Anthropic 客户端标准）",
              status_x != 401, f"status={status_x}")
        status_bad, _ = post(gw_port, "/v1/chat/completions",
                             {"model": "fake/fake-model", "max_tokens": 16,
                              "messages": [{"role": "user", "content": "hi"}]},
                             headers={"x-api-key": "wrong-token"})
        check("错误的 x-api-key 仍被拒绝（401）", status_bad == 401, f"status={status_bad}")
    finally:
        stop(gw)
        fake.shutdown()
    results["client-key"] = len(FAILURES) == 0

    # ---------------- 场景 14：CLI 参数排列组合（严格解析；用户裁决"只有一种显而易见写法"） ----------------
    print("场景 14: CLI 严格解析（冗余写法一律拒绝并给出正确指令；顺序无关；不触网不写文件）")
    workdir = scenario("cli-strict", "openai-only")
    base_env = dict(os.environ)
    base_env.pop("AUTO_COMPAT_MENU", None)
    base_env["FAKE_KEY"] = KEY
    fake_port = free_port()
    fake = start_fake(fake_port)
    probe_url = f"http://127.0.0.1:{fake_port}/v1"

    def run_cli(args, timeout=60, extra_env=None, stdin_text=None):
        env = dict(base_env)
        if extra_env:
            env.update(extra_env)
        return subprocess.run(
            [BIN, *args], cwd=workdir, env=env, capture_output=True, text=True, timeout=timeout,
            input=stdin_text, stdin=None if stdin_text is not None else subprocess.DEVNULL,
        )

    try:
        clear_requests()

        # (a) 未知选项 / 杂散参数：此前被静默忽略（--no-verfiy 会当成"没写"，拼错就白跑）
        r = run_cli(["probe", "--no-verfiy", "--key-env", "FAKE_KEY"])
        check("拼错的 --no-verfiy → exit 2 + 建议 --no-verify",
              r.returncode == 2 and "unknown option: --no-verfiy" in r.stderr and "did you mean --no-verify?" in r.stderr,
              f"rc={r.returncode} err={r.stderr[:200]}")
        r = run_cli(["probe", "foo"])
        check("杂散位置参数 → exit 2（不再静默跑预设探针）",
              r.returncode == 2 and "unexpected argument: foo" in r.stderr, f"rc={r.returncode} err={r.stderr[:200]}")

        # (b) 值缺失 / 空值 / 类型错误：此前 --out 会吞下一个选项当文件名、abc/-1 静默当 8
        r = run_cli(["probe", "--out"])
        check("--out 缺值 → exit 2 + missing value",
              r.returncode == 2 and "missing value for --out" in r.stderr, f"rc={r.returncode} err={r.stderr[:200]}")
        r = run_cli(["probe", "--key", "sk-x", "--out", "--no-verify"])
        check("--out 后跟选项 → 视为缺值（不吞成文件名、不留垃圾文件）",
              r.returncode == 2 and "missing value for --out" in r.stderr
              and not os.path.exists(os.path.join(workdir, "--no-verify")),
              f"rc={r.returncode} err={r.stderr[:200]}")
        r = run_cli(["probe", "--key", "sk-x", "--url", probe_url, "--out", ""])
        check("--out 空值 → exit 2 + empty value（此前跑完整个探针才报 FileNotFound）",
              r.returncode == 2 and "empty value for --out" in r.stderr, f"rc={r.returncode} err={r.stderr[:200]}")
        r = run_cli(["probe", "--key", "sk-x", "--url", "", "--no-verify"])
        check("--url 空值 → exit 2 + empty value（此前被静默丢弃）",
              r.returncode == 2 and "empty value for --url" in r.stderr, f"rc={r.returncode} err={r.stderr[:200]}")
        r = run_cli(["probe", "--key", "sk-x", "--url", probe_url, "--verify-models", "abc"])
        check("--verify-models 非数字 → exit 2（不再静默当默认 8）",
              r.returncode == 2 and "non-negative integer" in r.stderr, f"rc={r.returncode} err={r.stderr[:200]}")
        r = run_cli(["probe", "--key", "sk-x", "--url", probe_url, "--verify-models", "-1"])
        check("--verify-models 负数 → exit 2",
              r.returncode == 2 and "non-negative integer" in r.stderr, f"rc={r.returncode} err={r.stderr[:200]}")
        r = run_cli(["probe", "--key", "sk-x", "--url", probe_url, "--verify-models", "0"])
        check("--verify-models 0 → exit 2 + 指向 --no-verify（跳过验证只有一种写法）",
              r.returncode == 2 and "at least 1" in r.stderr and "--no-verify" in r.stderr, f"rc={r.returncode} err={r.stderr[:200]}")
        check("以上解析错误一次都没触网", len(STATE["requests"]) == 0, f"requests={chat_paths_in_log()}")

        # (c) help/version 只接受单独出现：带其它参数 = 冗余写法，拒绝并给出正确指令
        r = run_cli(["probe", "--help"])
        check("probe --help（单独）→ 用法 + exit 0",
              r.returncode == 0 and "usage: auto-compat probe" in r.stdout, f"rc={r.returncode} out={r.stdout[:160]}")
        r = run_cli(["probe", "--version"])
        check("probe --version（单独）→ 版本 + exit 0",
              r.returncode == 0 and re.fullmatch(r"auto-compat 0\.\d+\.\d+\n?", r.stdout or "") is not None,
              f"rc={r.returncode} out={r.stdout[:120]!r}")
        r = run_cli(["probe", "--out", "x.json", "--help"])
        check("probe --out x --help → exit 2 + 'takes no other arguments' + 正确指令",
              r.returncode == 2 and "takes no other arguments" in r.stderr and "auto-compat probe --help" in r.stderr,
              f"rc={r.returncode} err={r.stderr[:200]}")
        r = run_cli(["probe", "--key", "sk-x", "--out", "x.json", "--version"])
        check("probe --key sk --version → exit 2（不再顺便打印版本）",
              r.returncode == 2 and "takes no other arguments" in r.stderr, f"rc={r.returncode} err={r.stderr[:200]}")
        check("help/version 拒绝路径不触网、不写文件",
              len(STATE["requests"]) == 0 and not os.path.exists(os.path.join(workdir, "x.json")),
              f"requests={len(STATE['requests'])}")

        # (d) `--opt=VALUE` 是冗余写法：拒绝并提示唯一写法（此前被静默丢弃 → "no key"）
        r = run_cli(["probe", "--key=sk-e2e", f"--url={probe_url}", "--no-verify"])
        check("`--key=VALUE` / `--url=VALUE` → exit 2 + 指向 `--opt VALUE`",
              r.returncode == 2 and "--key=VALUE is not accepted" in r.stderr
              and "write --key VALUE" in r.stderr, f"rc={r.returncode} err={r.stderr[:200]}")
        r = run_cli(["probe", "--key", "sk-e2e", "--url", probe_url, "--out=x.json", "--no-verify"])
        check("`--out=VALUE` → exit 2 + 指向 `--out VALUE`",
              r.returncode == 2 and "write --out VALUE" in r.stderr and not os.path.exists(os.path.join(workdir, "x.json")),
              f"rc={r.returncode} err={r.stderr[:200]}")

        # (e) 选项顺序无关（同一组选项任意排列结果一致）
        orders = [
            ["--key", "sk-e2e", "--url", probe_url, "--out", "o1.json", "--no-verify"],
            ["--no-verify", "--out", "o2.json", "--url", probe_url, "--key", "sk-e2e"],
            ["--out", "o3.json", "--url", probe_url, "--key", "sk-e2e", "--no-verify"],
        ]
        for order in orders:
            r = run_cli(["probe", *order])
            check(f"选项排列（{order[0]} 开头）→ exit 0", r.returncode == 0, f"rc={r.returncode} err={r.stderr[-200:]}")
        frozen_seen = []
        for name in ("o1.json", "o2.json", "o3.json"):
            with open(os.path.join(workdir, name)) as fh:
                frozen_seen.append(json.load(fh))
        check("三种选项排列产物逐字一致（顺序无关）",
              frozen_seen[0] == frozen_seen[1] == frozen_seen[2], f"frozen={frozen_seen}")

        # (f) 重复选项 / 矛盾组合 / 两个 key 来源：全部拒绝（此前是"后者/某者静默胜出"）
        r = run_cli(["probe", "--key", "sk-e2e", "--url", probe_url, "--no-verify", "--out", "a.json", "--out", "b.json"])
        check("重复 --out → exit 2 + 'given more than once'（不生成任何文件）",
              r.returncode == 2 and "given more than once" in r.stderr
              and not os.path.exists(os.path.join(workdir, "a.json"))
              and not os.path.exists(os.path.join(workdir, "b.json")),
              f"rc={r.returncode} files={sorted(os.listdir(workdir))}")
        r = run_cli(["probe", "--key", "sk-e2e", "--key", "sk-other", "--url", probe_url])
        check("重复 --key → exit 2（同一设置只有一种写法：给一次）",
              r.returncode == 2 and "given more than once" in r.stderr, f"rc={r.returncode} err={r.stderr[:200]}")
        r = run_cli(["probe", "--no-verify", "--verify-paid", "--key", "sk-e2e", "--url", probe_url])
        check("--no-verify 与 --verify-paid 并存 → exit 2 + 'contradict; keep one'",
              r.returncode == 2 and "contradict; keep one" in r.stderr, f"rc={r.returncode} err={r.stderr[:200]}")
        r = run_cli(["probe", "--no-verify", "--verify-models", "3", "--key", "sk-e2e", "--url", probe_url])
        check("--no-verify 与 --verify-models 并存 → exit 2",
              r.returncode == 2 and "contradict; keep one" in r.stderr, f"rc={r.returncode} err={r.stderr[:200]}")
        clear_requests()
        r = run_cli(["probe", "--key-env", "FAKE_KEY", "--key", "sk-inline", "--url", probe_url])
        check("--key 与 --key-env 并存 → exit 2 + 'keep one'（不再静默让 inline 胜出）",
              r.returncode == 2 and "both given; keep one" in r.stderr, f"rc={r.returncode} err={r.stderr[:200]}")
        check("拒绝路径不触网", len(STATE["requests"]) == 0, f"requests={len(STATE['requests'])}")

        # (g) key 来源日志如实标注（inline 单独给出时）
        clear_requests()
        r = run_cli(["probe", "--key", "sk-inline", "--url", probe_url, "--no-verify", "--out", "prec.json"])
        auths = sorted({h["authorization"] for h in STATE["headers"] if h["authorization"]})
        check("--key 单独给出：上游收到 sk-inline 且日志标注 (inline --key)",
              r.returncode == 0 and auths == ["Bearer sk-inline"] and "(inline --key)" in r.stderr,
              f"rc={r.returncode} auths={auths} err={r.stderr[:200]}")

        # (h) serve/gateway 不再静默忽略参数；`gateway` 别名移除（只有一种写法：serve）
        r = run_cli(["serve", "--help"], timeout=20)
        check("serve --help → 用法 + exit 0（此前默默起网关挂住）",
              r.returncode == 0 and "usage:" in r.stdout, f"rc={r.returncode} out={r.stdout[:120]}")
        r = run_cli(["serve", "--port", "9000"], timeout=20)
        check("serve --port 9000 → exit 2 + 指向环境变量（此前静默监听 8686）",
              r.returncode == 2 and "unexpected argument: --port" in r.stderr
              and "AUTO_COMPAT_GATEWAY_PORT" in r.stderr, f"rc={r.returncode} err={r.stderr[:200]}")
        r = run_cli(["gateway"])
        check("gateway 别名移除 → exit 2 + 正确指令 'use `serve`'",
              r.returncode == 2 and "unknown command: gateway" in r.stderr and "use `serve`" in r.stderr,
              f"rc={r.returncode} err={r.stderr[:200]}")

        # (i) 未知子命令给建议；help/version 带多余参数给出正确指令；无效环境变量被点名
        r = run_cli(["-v"], timeout=20)
        check("未知子命令 -v → exit 2 + 'did you mean -V?'",
              r.returncode == 2 and "did you mean -V?" in r.stderr, f"rc={r.returncode} err={r.stderr[:200]}")
        r = run_cli(["help", "probe"], timeout=20)
        check("help probe → exit 2 + 指向 auto-compat probe --help",
              r.returncode == 2 and "unexpected argument: probe" in r.stderr
              and "auto-compat probe --help" in r.stderr, f"rc={r.returncode} err={r.stderr[:200]}")
        r = run_cli(["version", "--json"], timeout=20)
        check("version --json → exit 2（help/version 不带参数）",
              r.returncode == 2 and "unexpected argument: --json" in r.stderr, f"rc={r.returncode} err={r.stderr[:200]}")
        brief = run_brief(workdir, {"AUTO_COMPAT_GATEWAY_PORT": "abc"}, args=[])
        check("无效 AUTO_COMPAT_GATEWAY_PORT 被点名 + 实际默认值（不再静默回退）",
              "AUTO_COMPAT_GATEWAY_PORT" in brief and "8686" in brief, f"log={brief[:300]}")
        brief = run_brief(workdir, {"AUTO_COMPAT_GATEWAY_PORT": "0"})
        check("GATEWAY_PORT=0 单独说明（1..65535）",
              "must be 1..65535" in brief, f"log={brief[:300]}")
        brief = run_brief(workdir, {"AUTO_COMPAT_IDLE_TIMEOUT_MS": "abc",
                                    "AUTO_COMPAT_PLACEHOLDER_MS": "abc",
                                    "AUTO_COMPAT_RETRY_DELAY_MS": "abc"})
        check("三个旋钮的无效值都被点名（实际值仍是默认 600000/55000/100）",
              "AUTO_COMPAT_IDLE_TIMEOUT_MS" in brief and "600000" in brief
              and "AUTO_COMPAT_PLACEHOLDER_MS" in brief and "55000" in brief
              and "AUTO_COMPAT_RETRY_DELAY_MS" in brief, f"log={brief[:400]}")
        r = run_cli([], timeout=20, extra_env={"AUTO_COMPAT_GATEWAY_HOST": "999.999.999.999"})
        check("无效 AUTO_COMPAT_GATEWAY_HOST → 点名变量 + exit 2（此前是裸 'error: Overflow'）",
              r.returncode == 2 and "AUTO_COMPAT_GATEWAY_HOST" in r.stderr, f"rc={r.returncode} err={r.stderr[:200]}")

        # (j) 菜单只认屏幕上的键（1/2/3/q）；文字别名与向导多余写法都拒绝并提示
        menu_run = run_cli([], timeout=20, extra_env={"AUTO_COMPAT_MENU": "1"}, stdin_text="probe\nq\n")
        check("菜单输入文字别名 probe → invalid choice + 提示 1/2/3/q",
              "invalid choice: use 1, 2, 3, or q" in menu_run.stdout, f"out={menu_run.stdout[-200:]}")

        # (k) 向导：非数字/0/非 y-n 都重问；等价命令包含 --verify-paid
        wizard = run_cli([], timeout=60, extra_env={"AUTO_COMPAT_MENU": "1"},
                         stdin_text=f"2\nsk-wiz\n{probe_url}\n\nabc\n0\n3\nmaybe\ny\nq\n")
        check("向导对非数字重问（not a non-negative integer）",
              "not a non-negative integer" in wizard.stdout, f"out={wizard.stdout[-300:]}")
        check("向导对 0 重问（give a number >= 1，指向 CLI 的 --no-verify）",
              "give a number >= 1" in wizard.stdout and "--no-verify" in wizard.stdout,
              f"out={wizard.stdout[-400:]}")
        check("向导对非 y/n 重问（answer y or n）",
              "answer y or n" in wizard.stdout, f"out={wizard.stdout[-300:]}")
        check("向导等价命令含 --verify-models 3 与 --verify-paid（回显可复现）",
              "--verify-models 3" in wizard.stdout and "--verify-paid" in wizard.stdout,
              f"out={wizard.stdout[-400:]}")
        check("向导流程 exit 0", wizard.returncode == 0, f"rc={wizard.returncode}")
    finally:
        fake.shutdown()
    results["cli-strict"] = len(FAILURES) == 0

    # ---------------- 场景 15：Responses 方言的失败信号是规范形状 ----------------
    # 背景（真机反馈）：客户端（Responses 模式）在上游 502/429 重试耗尽后只看到"空响应"——
    # 因为 response.failed 缺 id/object/status，非流式又把流事件形状当 HTTP 错误体发。
    print("场景 15: Responses 失败信号（流式 response.failed 完整对象；非流式标准错误信封）")
    workdir = scenario("responses-fail", "always-502")
    for protocol in ("responses", "openai"):
        fake_port = free_port()
        gw_port = free_port()
        write_providers(workdir, [{"name": "fake", "baseURL": f"http://127.0.0.1:{fake_port}/v1",
                                   "apiKeyEnv": "FAKE_UNSET_KEY", "protocol": protocol}])
        fake = start_fake(fake_port)
        gw = start_gateway(gw_port, workdir)
        try:
            clear_requests()
            # 非流式：HTTP 502 + 标准错误信封（客户端读顶层 error.message/type/code）
            status, body = post(gw_port, "/v1/responses", {"model": "fake/fake-model", "input": "hi"},
                                headers={"x-api-key": "sk-e2e"})
            payload = json.loads(body)
            error_object = payload.get("error", {})
            check(f"[{protocol}] 非流式失败 = 标准错误信封（顶层 error.message/type/code）",
                  status == 502 and error_object.get("message") == "upstream boom"
                  and error_object.get("type") == "gateway_error" and error_object.get("code") == "SERVER",
                  f"status={status} body={body[:300]}")

            # 流式：HTTP 200 + 规范 response.failed（完整 Response 对象，客户端可识别失败）
            status2, body2 = post(gw_port, "/v1/responses",
                                  {"model": "fake/fake-model", "input": "hi", "stream": True},
                                  headers={"x-api-key": "sk-e2e"})
            data_lines = [line[len("data: "):] for line in body2.splitlines() if line.startswith("data: ")]
            failed = json.loads(data_lines[0]) if data_lines else {}
            response_object = failed.get("response", {})
            failure_object = response_object.get("error", {})
            check(f"[{protocol}] 流式失败帧 = response.failed + status=failed + 完整对象字段",
                  status2 == 200 and "event: response.failed" in body2
                  and failed.get("type") == "response.failed"
                  and response_object.get("object") == "response"
                  and response_object.get("status") == "failed"
                  and str(response_object.get("id", "")).startswith("resp_")
                  and response_object.get("model") == "fake/fake-model"
                  and isinstance(response_object.get("output"), list)
                  and failure_object.get("code") == "SERVER"
                  and failure_object.get("message") == "upstream boom",
                  f"status={status2} body={body2[:400]}")
            check(f"[{protocol}] 失败流不含 response.completed（不谎报完成）",
                  "response.completed" not in body2, f"body={body2[:300]}")
            check(f"[{protocol}] response.failed 带 created_at（严格客户端 schema 要求）",
                  isinstance(response_object.get("created_at"), int), f"response={response_object}")
        finally:
            stop(gw)
            fake.shutdown()
    results["responses-fail"] = len(FAILURES) == 0

    # ---------------- 场景 16：原生方言反复失败 → 换方言（翻译）兜底 ----------------
    # 用户要求："下游强求 responses 格式，就按上游实际存在的格式映射给他"。
    # 假上游：/responses 一律 502，/chat/completions 正常 → 客户端仍应拿到 Responses 格式的完整回答。
    print("场景 16: 上游 /responses 坏、chat 正常 → 重试耗尽后换方言翻译，客户端拿到完整回答")
    workdir = scenario("dialect-fallback", "responses-broken")
    fake_port = free_port()
    gw_port = free_port()
    write_providers(workdir, [{"name": "fake", "baseURL": f"http://127.0.0.1:{fake_port}/v1",
                               "apiKeyEnv": "FAKE_UNSET_KEY", "protocol": "openai"}])
    fake = start_fake(fake_port)
    gw = start_gateway(gw_port, workdir)
    try:
        clear_requests()
        # (a) 非流式：native responses 尝试（502×3）→ 换 openai → 翻译回 Responses 信封
        status, body = post(gw_port, "/v1/responses", {"model": "fake/fake-model", "input": "hi"},
                            headers={"x-api-key": "sk-e2e", "x-request-id": "e2e-trace-1"})
        payload = json.loads(body)
        output = payload.get("output", [])
        texts = [part.get("text") for item in output for part in item.get("content", [])]
        check("非流式：客户端拿到 Responses 格式的成功回答（translate fallback）",
              status == 200 and payload.get("status") == "completed" and "ok" in texts,
              f"status={status} body={body[:300]}")
        responses_calls = [p for p in post_paths_in_log() if p.endswith("/responses")]
        chat_calls = [p for p in post_paths_in_log() if p.endswith("chat/completions")]
        check("上游先试原生 /responses 失败，再走 /chat/completions 成功",
              len(responses_calls) == 3 and len(chat_calls) >= 1,
              f"responses={responses_calls} chat={chat_calls}")

        # (b) 第二条请求：原生已记为不可用 → 直走映射（不再白试 /responses）
        clear_requests()
        status2, body2 = post(gw_port, "/v1/responses", {"model": "fake/fake-model", "input": "hi again"},
                              headers={"x-api-key": "sk-e2e"})
        payload2 = json.loads(body2)
        check("第二条请求：直走映射成功（200）", status2 == 200 and payload2.get("status") == "completed",
              f"status={status2} body={body2[:200]}")
        check("第二条请求不再触碰 /responses（原生不可用已记忆）",
              not any(p.endswith("/responses") for p in post_paths_in_log()),
              f"posts={post_paths_in_log()}")

        # (c) 流式：同样换方言翻译，客户端拿到规范 SSE（created → delta → completed）
        clear_requests()
        status3, body3 = post(gw_port, "/v1/responses",
                              {"model": "fake/fake-model", "input": "hi", "stream": True},
                              headers={"x-api-key": "sk-e2e"})
        check("流式：翻译兜底后是规范 SSE（created + output_text.delta + completed）",
              status3 == 200 and "event: response.created" in body3
              and "response.output_text.delta" in body3 and "event: response.completed" in body3
              and '"ok"' in body3, f"status={status3} body={body3[:300]}")
    finally:
        stop(gw)
        log = gateway_log(gw)
        fake.shutdown()
    check("诊断：入站摘要一行（inbound responses model=… stream=…）",
          "inbound responses model=fake/fake-model" in log and "stream=0" in log, f"log_tail={log[-500:]}")
    check("诊断：每次上游尝试一行（attempt 1/7 + FAILED http=502 + 耗时）",
          "attempt 1/7" in log and "FAILED http=502 code=SERVER" in log and "ms msg=" in log,
          f"log_tail={log[-500:]}")
    check("诊断：客户端 x-request-id 贯穿日志（#e2e-trace-1）",
          "#e2e-trace-1" in log, f"log_tail={log[-500:]}")
    check("日志讲清触发原因（failed after retries → mapping via openai）",
          "failed after retries" in log and "mapping via openai" in log, f"log_tail={log[-400:]}")
    check("每个请求有汇总行（OK/FAILED + attempts/switches + 耗时）",
          "OK attempts=" in log or "FAILED code=" in log, f"log_tail={log[-400:]}")
    results["dialect-fallback"] = len(FAILURES) == 0

    # ---------------- 场景 17：三方言互备环（任意一条出问题 → 沿环试另外两个） ----------------
    print("场景 17: 三方言互备环（responses+chat 坏 → anthropic 顶上；chat 坏 → 换 responses）")
    workdir = scenario("dialect-ring", "chat-responses-broken")
    fake_port = free_port()
    fake = start_fake(fake_port)

    # 17a：responses 入站；/responses 与 /chat/completions 都坏，只有 /messages 可用
    gw_port = free_port()
    write_providers(workdir, [{"name": "fake", "baseURL": f"http://127.0.0.1:{fake_port}/v1",
                               "apiKeyEnv": "FAKE_UNSET_KEY", "protocol": "openai"}])
    gw = start_gateway(gw_port, workdir)
    try:
        clear_requests()
        status, body = post(gw_port, "/v1/responses", {"model": "fake/fake-model", "input": "hi"},
                            headers={"x-api-key": "sk-e2e"})
        payload = json.loads(body)
        texts = [part.get("text") for item in payload.get("output", []) for part in item.get("content", [])]
        check("17a：两条方言坏 → 第三条 anthropic 顶上，responses 入站仍拿到完整回答",
              status == 200 and payload.get("status") == "completed" and "ok" in texts,
              f"status={status} body={body[:300]}")
        paths = post_paths_in_log()
        check("17a：上游按环序试过 /responses → /chat/completions → /messages",
              any(p.endswith("/responses") for p in paths)
              and any(p.endswith("chat/completions") for p in paths)
              and any(p.endswith("/messages") for p in paths),
              f"posts={paths}")
    finally:
        stop(gw)
        log_a = gateway_log(gw)

    # 17b：chat 入站；只有 /chat/completions 坏 → 应换到 responses 翻译（新网关：坏记忆是进程内的）
    STATE["mode"] = "chat-broken"
    gw_port2 = free_port()
    gw2 = start_gateway(gw_port2, workdir)
    try:
        clear_requests()
        status2, body2 = post(gw_port2, "/v1/chat/completions",
                              {"model": "fake/fake-model", "max_tokens": 16,
                               "messages": [{"role": "user", "content": "hi"}]},
                              headers={"x-api-key": "sk-e2e"})
        check("17b：chat 坏 → 换 responses 翻译，chat 入站拿到 200 回答",
              status2 == 200 and "ok" in body2, f"status={status2} body={body2[:200]}")
        chat_calls = chat_paths_in_log()
        check("17b：上游先试过坏掉的 /chat/completions（重试），再走其它方言",
              len(chat_calls) >= 1, f"chat_calls={chat_calls}")
    finally:
        stop(gw2)
        log_b = gateway_log(gw2)
        fake.shutdown()
    check("17a 日志：两次换方言都留痕（mapping via …，2/3、3/3）",
          "mapping via" in log_a and "(2/3 dialects tried)" in log_a and "(3/3 dialects tried)" in log_a,
          f"log_tail={log_a[-500:]}")
    check("17b 日志：chat 失败后换方言留痕",
          "mapping via" in log_b, f"log_tail={log_b[-400:]}")
    results["dialect-ring"] = len(FAILURES) == 0

    # ---------------- 场景 18：系统提示归一（instructions / system 消息必须到达上游） ----------------
    print("场景 18: 系统提示归一（chat 入站 system 消息 / responses 入站 instructions → 上游可见）")
    workdir = scenario("system-prompt", "openai-only")
    fake_port = free_port()
    gw_port = free_port()
    write_providers(workdir, [{"name": "fake", "baseURL": f"http://127.0.0.1:{fake_port}/v1",
                               "apiKeyEnv": "FAKE_KEY", "protocol": "openai"}])
    fake = start_fake(fake_port)
    gw = start_gateway(gw_port, workdir)
    try:
        def body_texts():
            bodies = json.dumps([b for (_m, _p, b) in STATE["requests"]], ensure_ascii=False)
            return bodies

        # (a) chat 入站：system 消息必须出现在上游请求体里
        clear_requests()
        status1, _ = post(gw_port, "/v1/chat/completions",
                          {"model": "fake/fake-model", "max_tokens": 16,
                           "messages": [{"role": "system", "content": "SYS-CHAT-PROMPT"},
                                        {"role": "user", "content": "hi"}]})
        check("chat 入站：系统提示到达上游（此前被整个丢掉）",
              status1 == 200 and "SYS-CHAT-PROMPT" in body_texts(), f"status={status1} bodies={body_texts()[:300]}")

        # (b) responses 入站：instructions 必须到达上游（openai-only 上游 → 走映射到 chat）
        clear_requests()
        status2, _ = post(gw_port, "/v1/responses",
                          {"model": "fake/fake-model", "instructions": "SYS-RESP-PROMPT",
                           "input": [{"type": "message", "role": "user", "content": [{"type": "input_text", "text": "hi"}]}]})
        check("responses 入站：instructions 到达上游（此前被整个丢掉）",
              status2 == 200 and "SYS-RESP-PROMPT" in body_texts(), f"status={status2} bodies={body_texts()[:300]}")

        # (c) anthropic 入站：system 一直工作，回归确认
        clear_requests()
        status3, _ = post(gw_port, "/v1/messages",
                          {"model": "fake/fake-model", "max_tokens": 16, "system": "SYS-ANTH-PROMPT",
                           "messages": [{"role": "user", "content": "hi"}]})
        check("anthropic 入站：system 仍到达上游（回归）",
              status3 == 200 and "SYS-ANTH-PROMPT" in body_texts(), f"status={status3} bodies={body_texts()[:300]}")
    finally:
        stop(gw)
        fake.shutdown()
    results["system-prompt"] = len(FAILURES) == 0

    # ---------------- 场景 19：Responses 事件规范字段（zcode 逐事件 schema 校验） ----------------
    print("场景 19: Responses 事件规范字段（created_at / item id / item_id / status）")
    workdir = scenario("responses-wire", "openai-only")
    fake_port = free_port()
    gw_port = free_port()
    write_providers(workdir, [{"name": "fake", "baseURL": f"http://127.0.0.1:{fake_port}/v1",
                               "apiKeyEnv": "FAKE_KEY", "protocol": "openai"}])
    fake = start_fake(fake_port)
    gw = start_gateway(gw_port, workdir)
    try:
        clear_requests()
        status, body = post(gw_port, "/v1/responses",
                            {"model": "fake/fake-model", "input": "hi", "stream": True},
                            headers={"x-api-key": "sk-e2e"})
        frames = {}
        for event_name, data in re.findall(r"event: (\S+)\ndata: (.*)", body):
            frames.setdefault(event_name, []).append(json.loads(data))
        created = (frames.get("response.created") or [{}])[0]
        added = (frames.get("response.output_item.added") or [{}])[0]
        deltas = frames.get("response.output_text.delta") or []
        done = (frames.get("response.output_item.done") or [{}])[0]
        item_id = added.get("item", {}).get("id", "")
        check("流式：response.created 带 created_at（严格客户端必需）",
              isinstance(created.get("response", {}).get("created_at"), int),
              f"created={created}")
        check("流式：output_item.added 的 item 带 id（缺失会被整条丢弃）",
              isinstance(item_id, str) and item_id.startswith("msg_"),
              f"added={added}")
        check("流式：output_text.delta 带 item_id + content_index，且与 item.id 一致",
              len(deltas) > 0 and deltas[0].get("item_id") == item_id
              and deltas[0].get("content_index") == 0,
              f"deltas={deltas}")
        check("流式：output_item.done 带 id + status=completed",
              done.get("item", {}).get("id") == item_id
              and done.get("item", {}).get("status") == "completed",
              f"done={done}")
        completed = (frames.get("response.completed") or [{}])[0].get("response", {})
        check("流式：response.completed 带 usage + created_at（客户端结算与 schema 校验）",
              isinstance(completed.get("usage"), dict) and isinstance(completed.get("created_at"), int),
              f"completed={frames.get('response.completed')}")

        # 非流式：同一套规范字段
        clear_requests()
        status2, body2 = post(gw_port, "/v1/responses", {"model": "fake/fake-model", "input": "hi"},
                              headers={"x-api-key": "sk-e2e"})
        payload = json.loads(body2)
        output = payload.get("output") or []
        check("非流式：created_at + output[].id/status 齐全",
              status2 == 200 and isinstance(payload.get("created_at"), int)
              and len(output) > 0 and isinstance(output[0].get("id"), str)
              and output[0].get("status") == "completed",
              f"status={status2} body={body2[:300]}")
    finally:
        stop(gw)
        fake.shutdown()
    results["responses-wire"] = len(FAILURES) == 0

    print()
    if FAILURES:
        print(f"失败 {len(FAILURES)} 项: {FAILURES}")
        sys.exit(1)
    print("全部场景通过 ✅")


if __name__ == "__main__":
    main()