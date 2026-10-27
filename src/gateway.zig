//! 网关：路由（/vN 前缀剥离）、鉴权、自描述、三方言 handlers。
const std = @import("std");
const types = @import("types.zig");
const http_util = @import("http_util.zig");
const providers_mod = @import("providers.zig");
const openai = @import("upstream/openai.zig");
const inbound_openai = @import("inbound/openai.zig");
const inbound_anthropic = @import("inbound/anthropic.zig");
const inbound_responses = @import("inbound/responses.zig");
const router_mod = @import("router.zig");
const version = @import("version.zig");
const watchdog_mod = @import("watchdog.zig");
const placeholder_mod = @import("placeholder.zig");
const clock = @import("clock.zig");
const env = @import("env.zig");
const client_key = @import("client_key.zig");
const diag = @import("diag.zig");

const max_body_bytes: usize = 64 * 1024 * 1024;

pub const Config = struct {
    host: []const u8 = "127.0.0.1",
    port: u16 = 8686,
    token: []const u8 = "",
};

pub fn handleConnection(
    io: std.Io,
    stream: std.Io.net.Stream,
    registry: *providers_mod.Registry,
    config: *const Config,
    route_cache: *router_mod.Cache,
) void {
    defer stream.close(io);
    var read_buf: [16384]u8 = undefined;
    var write_buf: [16384]u8 = undefined;
    var conn_reader = stream.reader(io, &read_buf);
    var conn_writer = stream.writer(io, &write_buf);
    var server = std.http.Server.init(&conn_reader.interface, &conn_writer.interface);

    // keep-alive：receiveHead 返回 HttpConnectionClosing（或其他错误）时退出循环。
    while (true) {
        var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        var request = server.receiveHead() catch break;
        handle(arena, io, &request, registry, config, route_cache) catch |err| {
            std.debug.print("[llm-shim] request failed: {s}\n", .{@errorName(err)});
            // 兜底：必须回写响应，否则客户端连接挂起
            const message = std.fmt.allocPrint(arena, "{{\"error\":{{\"message\":\"internal: {s}\",\"type\":\"gateway_error\",\"code\":\"GATEWAY_FAILURE\"}}}}", .{@errorName(err)}) catch null;
            if (message) |body| {
                respondJson(&request, .internal_server_error, body) catch {};
            }
        };
    }
}

fn authorized(request: *std.http.Server.Request, token: []const u8) bool {
    if (token.len == 0) return true;
    var iterator = request.iterateHeaders();
    while (iterator.next()) |header| {
        // Anthropic 标准客户端只发 x-api-key（不发明 Authorization）；两种载体都认。
        if (std.ascii.eqlIgnoreCase(header.name, "x-api-key")) {
            if (http_util.timingSafeEqual(header.value, token)) return true;
            continue;
        }
        if (std.ascii.eqlIgnoreCase(header.name, "authorization")) {
            const presented = if (std.mem.startsWith(u8, header.value, "Bearer "))
                header.value["Bearer ".len..]
            else
                header.value;
            if (http_util.timingSafeEqual(presented, token)) return true;
        }
    }
    return false;
}

fn handle(
    arena: std.mem.Allocator,
    io: std.Io,
    request: *std.http.Server.Request,
    registry: *providers_mod.Registry,
    config: *const Config,
    route_cache: *router_mod.Cache,
) !void {
    // 请求级诊断 id：并发/重试交错时按 id 对齐日志（客户端 x-request-id 优先）。
    const client_request_id: ?[]const u8 = blk: {
        var iterator = request.iterateHeaders();
        while (iterator.next()) |header| {
            if (std.ascii.eqlIgnoreCase(header.name, "x-request-id")) break :blk header.value;
        }
        break :blk null;
    };
    _ = diag.begin(arena, client_request_id) catch {};
    defer diag.clear();

    if (!authorized(request, config.token)) {
        diag.print("auth rejected: no matching Authorization/x-api-key\n", .{});
        return respondJsonError(request, .unauthorized, "gateway authentication required", "UNAUTHORIZED");
    }
    // key 中转：挑出入站携带的上游凭据（网关令牌除外），dupe 进请求 arena（头部缓冲可能被 body 复用），
    // 线程本地存放，供适配器在环境变量缺失时透传给上游。
    const inbound_key: ?[]const u8 = blk: {
        var x_api_key: ?[]const u8 = null;
        var authorization: ?[]const u8 = null;
        var iterator = request.iterateHeaders();
        while (iterator.next()) |header| {
            if (std.ascii.eqlIgnoreCase(header.name, "x-api-key")) {
                if (x_api_key == null) x_api_key = header.value;
            } else if (std.ascii.eqlIgnoreCase(header.name, "authorization")) {
                if (authorization == null) authorization = header.value;
            }
        }
        const picked = client_key.pick(x_api_key, authorization, config.token) orelse break :blk null;
        break :blk try arena.dupe(u8, picked);
    };
    client_key.set(inbound_key);
    defer client_key.clear();
    var raw_path = request.head.target;
    if (std.mem.indexOfScalar(u8, raw_path, '?')) |question| raw_path = raw_path[0..question];
    const path = http_util.stripVersionPrefix(raw_path);
    const method = request.head.method;
    diag.print("{s} {s}\n", .{ @tagName(method), raw_path });

    if (method == .GET and (std.mem.eql(u8, path, "/") or path.len == 0)) {
        return respondSelfDescription(arena, request, registry, config);
    }
    if (method == .GET and std.mem.eql(u8, path, "/models")) {
        return respondModels(arena, request, registry);
    }
    if (method == .GET and std.mem.eql(u8, path, "/providers")) {
        return respondProviders(request, registry);
    }
    if (method == .POST and std.mem.eql(u8, path, "/chat/completions")) {
        return handleDialect(arena, io, request, registry, config, route_cache, .openai);
    }
    if (method == .POST and std.mem.eql(u8, path, "/responses")) {
        return handleDialect(arena, io, request, registry, config, route_cache, .responses);
    }
    if (method == .POST and std.mem.eql(u8, path, "/messages")) {
        return handleDialect(arena, io, request, registry, config, route_cache, .anthropic);
    }
    if (method == .POST and std.mem.eql(u8, path, "/messages/count_tokens")) {
        return handleCountTokens(arena, request);
    }

    const body = try std.fmt.allocPrint(arena, "{{\"error\":{{\"message\":\"no gateway route for {s} {s}; this gateway speaks openai-chat (/chat/completions), openai-responses (/responses) and anthropic (/messages) — any /vN prefix is tolerated\",\"type\":\"gateway_error\",\"code\":\"NOT_FOUND\"}}}}", .{ @tagName(method), raw_path });
    return respondJson(request, .not_found, body);
}

// ---------------------------------------------------------------------------
// 响应助手
// ---------------------------------------------------------------------------

pub fn respondJson(request: *std.http.Server.Request, status: std.http.Status, body: []const u8) !void {
    try request.respond(body, .{
        .status = status,
        .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }},
    });
}

fn respondJsonError(request: *std.http.Server.Request, status: std.http.Status, message: []const u8, code: []const u8) !void {
    // respond 同步写出后才释放，page_allocator 生命周期足够。
    var out: std.Io.Writer.Allocating = .init(std.heap.page_allocator);
    defer out.deinit();
    var stringify: std.json.Stringify = .{ .writer = &out.writer };
    try stringify.beginObject();
    try stringify.objectField("error");
    try stringify.beginObject();
    try stringify.objectField("message");
    try stringify.write(message);
    try stringify.objectField("type");
    try stringify.write("gateway_error");
    try stringify.objectField("code");
    try stringify.write(code);
    try stringify.endObject();
    try stringify.endObject();
    try respondJson(request, status, out.written());
}

/// 请求体里的模型名（三个方言都用 "model" 键）；缺失/非字符串返回 ""。
fn modelEcho(object: std.json.ObjectMap) []const u8 {
    const value = object.get("model") orelse return "";
    return if (value == .string) value.string else "";
}

/// AMBIGUOUS_MODEL 的可行动 400：列出候选供应商，并给出 provider/model 写法。
fn respondAmbiguousModel(
    arena: std.mem.Allocator,
    request: *std.http.Server.Request,
    registry: *providers_mod.Registry,
    model: []const u8,
) !void {
    const candidates = openai.ambiguousCandidates(arena, registry, model) catch &.{};
    if (candidates.len < 2) {
        // 理论上不可达（候选与 resolveProvider 判定同源）；保底回旧文案。
        return respondJsonError(request, .bad_request, "model matches several providers; use \"provider/model\"", "AMBIGUOUS_MODEL");
    }
    const message = try ambiguousMessage(arena, model, candidates);
    return respondJsonError(request, .bad_request, message, "AMBIGUOUS_MODEL");
}

/// 纯函数（可单测）：`model "glm-5.3" exists in: intern-ai, custom-1; use "provider/model", e.g. "intern-ai/glm-5.3" or "custom-1/glm-5.3"`。
fn ambiguousMessage(arena: std.mem.Allocator, model: []const u8, candidates: []const []const u8) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    try out.writer.print("model \"{s}\" exists in: ", .{model});
    for (candidates, 0..) |name, index| {
        if (index > 0) try out.writer.writeAll(", ");
        try out.writer.writeAll(name);
    }
    try out.writer.writeAll("; use \"provider/model\", e.g. ");
    for (candidates, 0..) |name, index| {
        if (index > 0) try out.writer.writeAll(" or ");
        try out.writer.print("\"{s}/{s}\"", .{ name, model });
    }
    return out.written();
}

// ---------------------------------------------------------------------------
// 自描述 / models / providers
// ---------------------------------------------------------------------------

fn respondSelfDescription(arena: std.mem.Allocator, request: *std.http.Server.Request, registry: *providers_mod.Registry, config: *const Config) !void {
    const accepts_html = blk: {
        var iterator = request.iterateHeaders();
        while (iterator.next()) |header| {
            if (std.ascii.eqlIgnoreCase(header.name, "accept") and
                std.mem.indexOf(u8, header.value, "text/html") != null) break :blk true;
        }
        break :blk false;
    };
    if (accepts_html) {
        const html =
            "<!doctype html><html lang=\"zh\"><head><meta charset=\"utf-8\"><title>llm-shim</title></head>" ++
            "<body><h1>llm-shim 网关</h1><p>任意 /vN 前缀被剥除后匹配同一张路由表。</p>" ++
            "<ul><li>POST /chat/completions — OpenAI Chat</li><li>POST /responses — OpenAI Responses</li>" ++
            "<li>POST /messages — Anthropic Messages</li><li>GET /models — 模型目录</li><li>GET /providers — 供应商视图</li></ul>" ++
            "<p>上游空闲超时 {d}ms / 占位保活 {d}ms（均可用环境变量调，0=关）；JSON 自描述：<code>curl http://HOST:PORT/</code></p></body></html>";
        return request.respond(try std.fmt.allocPrint(arena, html, .{ watchdog_mod.idleTimeoutMs(), placeholder_mod.thresholdMs() }), .{
            .extra_headers = &.{.{ .name = "content-type", .value = "text/html; charset=utf-8" }},
        });
    }
    var out: std.Io.Writer.Allocating = .init(arena);
    var stringify: std.json.Stringify = .{ .writer = &out.writer };
    try stringify.beginObject();
    try stringify.objectField("service");
    try stringify.write("llm-shim gateway");
    try stringify.objectField("version");
    try stringify.write(version.value);
    try stringify.objectField("note");
    try stringify.write("路径无固定后缀：/v1、/v2、任意 /vN 前缀都被剥除后按同一张路由表匹配；根路径直接访问亦可。");
    // 显式说明两条"等待/超时"限制（可调；0 = 关闭），便于机器读取与排障。
    try stringify.objectField("limits");
    try stringify.beginObject();
    try stringify.objectField("upstreamIdleTimeoutMs");
    try stringify.write(watchdog_mod.idleTimeoutMs());
    try stringify.objectField("upstreamIdleTimeoutEnabled");
    try stringify.write(watchdog_mod.idleTimeoutMs() > 0);
    try stringify.objectField("placeholderKeepaliveMs");
    try stringify.write(placeholder_mod.thresholdMs());
    try stringify.objectField("placeholderEnabled");
    try stringify.write(placeholder_mod.enabled());
    try stringify.endObject();
    try stringify.objectField("routes");
    try stringify.beginArray();
    const routes = [_]struct { method: []const u8, path: []const u8, dialect: []const u8, description: []const u8 }{
        .{ .method = "GET", .path = "/models", .dialect = "openai", .description = "聚合模型目录" },
        .{ .method = "GET", .path = "/providers", .dialect = "json", .description = "供应商视图（free/detected/模型数）" },
        .{ .method = "POST", .path = "/chat/completions", .dialect = "openai-chat", .description = "OpenAI Chat Completions 入站（流式/非流式）" },
        .{ .method = "POST", .path = "/responses", .dialect = "openai-responses", .description = "OpenAI Responses 入站（流式/非流式，store/previous_response_id 被无状态化）" },
        .{ .method = "POST", .path = "/messages", .dialect = "anthropic", .description = "Anthropic Messages 入站（流式/非流式）" },
        .{ .method = "POST", .path = "/messages/count_tokens", .dialect = "anthropic", .description = "本地近似 token 估算" },
        .{ .method = "GET", .path = "/", .dialect = "json/html", .description = "本自描述" },
    };
    for (routes) |route| {
        try stringify.beginObject();
        try stringify.objectField("method");
        try stringify.write(route.method);
        try stringify.objectField("path");
        try stringify.write(route.path);
        try stringify.objectField("dialect");
        try stringify.write(route.dialect);
        try stringify.objectField("description");
        try stringify.write(route.description);
        try stringify.endObject();
    }
    try stringify.endArray();
    try stringify.objectField("upstreams");
    try stringify.beginArray();
    for (registry.profiles.items) |*profile| {
        try stringify.beginObject();
        try stringify.objectField("id");
        try stringify.write(profile.name);
        try stringify.objectField("displayName");
        try stringify.write(profile.display_name);
        try stringify.objectField("models");
        try stringify.write(profile.models.len);
        try stringify.objectField("free");
        try stringify.write(profile.free);
        try stringify.objectField("detected");
        try stringify.write(profile.detected);
        try stringify.endObject();
    }
    try stringify.endArray();
    try stringify.objectField("examples");
    try stringify.beginObject();
    try stringify.objectField("openai");
    try stringify.write(try std.fmt.allocPrint(arena, "http://{s}:{d}/chat/completions", .{ config.host, config.port }));
    try stringify.objectField("responses");
    try stringify.write(try std.fmt.allocPrint(arena, "http://{s}:{d}/responses", .{ config.host, config.port }));
    try stringify.objectField("anthropic");
    try stringify.write(try std.fmt.allocPrint(arena, "http://{s}:{d}/messages", .{ config.host, config.port }));
    try stringify.objectField("models");
    try stringify.write(try std.fmt.allocPrint(arena, "http://{s}:{d}/models", .{ config.host, config.port }));
    try stringify.endObject();
    try stringify.endObject();
    return respondJson(request, .ok, out.written());
}

fn respondModels(arena: std.mem.Allocator, request: *std.http.Server.Request, registry: *providers_mod.Registry) !void {
    var out: std.Io.Writer.Allocating = .init(arena);
    var stringify: std.json.Stringify = .{ .writer = &out.writer };
    try stringify.beginObject();
    try stringify.objectField("object");
    try stringify.write("list");
    try stringify.objectField("data");
    try stringify.beginArray();
    // 先按 provider 追加 "provider/model"，再追加全局唯一的裸 id
    var bare_counts: std.StringHashMap(usize) = .init(arena);
    for (registry.profiles.items) |*profile| {
        for (profile.models) |model| {
            const count = bare_counts.get(model.id) orelse 0;
            bare_counts.put(model.id, count + 1) catch {};
        }
    }
    for (registry.profiles.items) |*profile| {
        for (profile.models) |model| {
            try stringify.beginObject();
            try stringify.objectField("id");
            try stringify.write(try std.fmt.allocPrint(arena, "{s}/{s}", .{ profile.name, model.id }));
            try stringify.objectField("object");
            try stringify.write("model");
            try stringify.objectField("owned_by");
            try stringify.write(profile.name);
            try stringify.endObject();
        }
    }
    var bare_iterator = bare_counts.iterator();
    while (bare_iterator.next()) |entry| {
        if (entry.value_ptr.* != 1) continue;
        try stringify.beginObject();
        try stringify.objectField("id");
        try stringify.write(entry.key_ptr.*);
        try stringify.objectField("object");
        try stringify.write("model");
        try stringify.objectField("owned_by");
        try stringify.write("llm-shim");
        try stringify.endObject();
    }
    try stringify.endArray();
    try stringify.endObject();
    return respondJson(request, .ok, out.written());
}

fn respondProviders(request: *std.http.Server.Request, registry: *providers_mod.Registry) !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var out: std.Io.Writer.Allocating = .init(arena);
    var stringify: std.json.Stringify = .{ .writer = &out.writer };
    try stringify.beginObject();
    try stringify.objectField("object");
    try stringify.write("list");
    try stringify.objectField("data");
    try stringify.beginArray();
    for (registry.profiles.items) |*profile| {
        try stringify.beginObject();
        try stringify.objectField("id");
        try stringify.write(profile.name);
        try stringify.objectField("displayName");
        try stringify.write(profile.display_name);
        try stringify.objectField("free");
        try stringify.write(profile.free);
        try stringify.objectField("detected");
        try stringify.write(profile.detected);
        try stringify.objectField("models");
        try stringify.write(profile.models.len);
        try stringify.endObject();
    }
    try stringify.endArray();
    try stringify.endObject();
    return respondJson(request, .ok, out.written());
}

// ---------------------------------------------------------------------------
// 方言 handlers（入站解析 → 带自愈的上游调用 → 入站组装）
// ---------------------------------------------------------------------------

fn handleDialect(
    arena: std.mem.Allocator,
    io: std.Io,
    request: *std.http.Server.Request,
    registry: *providers_mod.Registry,
    config: *const Config,
    route_cache: *router_mod.Cache,
    dialect: types.Protocol,
) !void {
    switch (dialect) {
        .openai => return handleOpenAi(arena, io, request, registry, config, route_cache),
        .anthropic => return handleAnthropic(arena, io, request, registry, config, route_cache),
        .responses => return handleResponses(arena, io, request, registry, config, route_cache),
    }
}

// ---------------------------------------------------------------------------
// OpenAI Chat 方言
// ---------------------------------------------------------------------------

// threadlocal 传状态给 comptime 回调（每连接线程独立，安全）。
threadlocal var sink_chunks: ?*std.ArrayList(types.Chunk) = null;
threadlocal var sink_arena: ?std.mem.Allocator = null;
threadlocal var sink_failure: ?*?openai.Failure = null;
threadlocal var sink_stream_out: ?*inbound_openai.StreamOut = null;
threadlocal var sink_body: ?*std.http.BodyWriter = null;
threadlocal var sink_frames_sent: ?*bool = null;
/// 占位保活：客户端写入互斥锁与"上次写入时间"（看门狗线程与本线程共用）。
/// 写入必须持锁，否则占位帧会插进真实帧中间。
threadlocal var sink_client_mutex: ?*std.Io.Mutex = null;
threadlocal var sink_last_write_ms: ?*std.atomic.Value(i64) = null;
/// 上游最近一次 chunk 到达时间（空闲超时依据；与"客户端写入时间"语义不同）。
threadlocal var sink_last_chunk_ms: ?*std.atomic.Value(i64) = null;
threadlocal var sink_io: ?std.Io = null;

fn onChunkForward(_: void, chunk: types.Chunk) !void {
    // 上游有 chunk = 有生命迹象：刷新空闲超时计时
    if (sink_last_chunk_ms) |stamp| stamp.store(clock.unixMilli(), .release);
    // 流式：转帧写出
    if (sink_stream_out) |out| {
        const frames = try out.write(chunk);
        if (sink_body) |body_writer| {
            if (sink_client_mutex) |mutex| {
                mutex.lockUncancelable(sink_io.?);
                defer mutex.unlock(sink_io.?);
                for (frames) |frame| try body_writer.writer.writeAll(frame);
                if (frames.len > 0) {
                    try http_util.flushBody(body_writer);
                    if (sink_frames_sent) |flag| flag.* = true;
                    if (sink_last_write_ms) |stamp| stamp.store(clock.unixMilli(), .release);
                }
                return;
            }
            for (frames) |frame| try body_writer.writer.writeAll(frame);
            if (frames.len > 0) {
                try http_util.flushBody(body_writer);
                if (sink_frames_sent) |flag| flag.* = true;
            }
        }
        return;
    }
    // 非流式：收集
    if (sink_chunks) |list| {
        const arena = sink_arena orelse return;
        try list.append(arena, chunk);
        if (chunk == .finish and chunk.finish == .failure) {
            if (sink_failure) |failure_slot| {
                failure_slot.* = .{ .status = 502, .code = chunk.finish.failure.code, .message = chunk.finish.failure.message };
            }
        }
    }
}

fn handleOpenAi(
    arena: std.mem.Allocator,
    io: std.Io,
    request: *std.http.Server.Request,
    registry: *providers_mod.Registry,
    config: *const Config,
    route_cache: *router_mod.Cache,
) !void {
    _ = config;
    const body_text = try readBody(arena, request);
    const parsed_json = std.json.parseFromSliceLeaky(std.json.Value, arena, body_text, .{}) catch {
        return respondJsonError(request, .bad_request, "request body is not valid JSON", "INVALID_JSON");
    };
    if (parsed_json != .object) {
        return respondJsonError(request, .bad_request, "request body must be an object", "INVALID_JSON");
    }
    const parsed = inbound_openai.parse(arena, registry, parsed_json.object) catch |err| {
        diag.print("inbound parse failed: {s}\n", .{@errorName(err)});
        switch (err) {
        error.MissingModel => return respondJsonError(request, .bad_request, "missing \"model\"", "INVALID_REQUEST"),
        error.MissingMessages => return respondJsonError(request, .bad_request, "missing \"messages\"", "INVALID_REQUEST"),
        error.EmptyRequest => return respondJsonError(request, .bad_request, "no usable messages after normalization", "EMPTY_REQUEST"),
        error.UnknownModel => return respondJsonError(request, .bad_request, "unknown model; see GET /models", "UNKNOWN_MODEL"),
        error.AmbiguousModel => {
            diag.print("ambiguous model: {s}\n", .{modelEcho(parsed_json.object)});
            return respondAmbiguousModel(arena, request, registry, modelEcho(parsed_json.object));
        },
        else => return err,
        }
    };
    diag.print("inbound openai-chat model={s} stream={d} msgs={d} system={d}B tools={d} max_tokens={d}\n", .{
        parsed.model_echo, @intFromBool(parsed.stream), parsed.request.messages.len,
        if (parsed.request.system) |system| system.len else 0,
        if (parsed.request.tools) |tools| tools.len else 0,
        parsed.request.max_tokens orelse 0,
    });
    // Cline 兼容：透传留痕（内容不打印——only/has 是客户端的路由意图，字节数足够对账）。
    if (parsed.request.provider_options) |po| {
        diag.print("providerOptions passthrough ({d}B) to openai upstream\n", .{po.len});
    }

    // 看门狗注册（流式/非流式都注册）：非流式只能做空闲超时（body=null → 不注入占位），
    // 流式随后回填 stream_out/body。没有它黑洞上游会把请求永久挂住。
    var frames_sent = false;
    var placeholder_sent = false;
    var finished_flag = std.atomic.Value(bool).init(false);
    var last_write_ms = std.atomic.Value(i64).init(clock.unixMilli());
    var last_chunk_ms = std.atomic.Value(i64).init(clock.unixMilli());
    var timed_out_flag = std.atomic.Value(bool).init(false);
    var client_mutex: std.Io.Mutex = .init;
    var watchdog_entry = watchdog_mod.Entry{
        .io = io,
        .dialect = .openai,
        .stream_out = null,
        .body = null,
        .mutex = &client_mutex,
        .placeholder_sent = &placeholder_sent,
        .last_write_ms = &last_write_ms,
        .finished = &finished_flag,
        .last_chunk_ms = &last_chunk_ms,
        .idle_timeout_ms = watchdog_mod.idleTimeoutMs(),
        .timed_out = &timed_out_flag,
    };
    watchdog_mod.register(&watchdog_entry);
    watchdog_mod.bindCurrent(&watchdog_entry);
    sink_client_mutex = &client_mutex;
    sink_last_write_ms = &last_write_ms;
    sink_last_chunk_ms = &last_chunk_ms;
    sink_io = io;
    defer {
        watchdog_mod.unregister(&watchdog_entry);
        watchdog_mod.unbindCurrent();
        sink_client_mutex = null;
        sink_last_write_ms = null;
        sink_last_chunk_ms = null;
        sink_io = null;
    }

    if (!parsed.stream) {
        // 非流式：收集全部 chunks → assemble
        var chunks: std.ArrayList(types.Chunk) = .empty;
        var failure: ?openai.Failure = null;
        sink_chunks = &chunks;
        sink_arena = arena;
        sink_failure = &failure;
        sink_stream_out = null;
        sink_body = null;
        sink_frames_sent = &frames_sent;
        defer {
            sink_chunks = null;
            sink_arena = null;
            sink_failure = null;
            sink_frames_sent = null;
        }
        _ = router_mod.callHealed(arena, io, route_cache, registry.find(parsed.request.provider).?, .openai, parsed.request, &failure, {}, onChunkForward, &frames_sent) catch |err| {
            finished_flag.store(true, .release);
            if (failure) |failure_value| {
                const message = try std.fmt.allocPrint(arena, "{s}: HTTP {d} {s}", .{ "llm-shim", failure_value.status, failure_value.message });
                return respondJsonError(request, .bad_gateway, message, failure_value.code);
            }
            return respondJsonError(request, .bad_gateway, @errorName(err), "GATEWAY_FAILURE");
        };
        finished_flag.store(true, .release);
        const response_body = try inbound_openai.assembleNonStream(arena, parsed.model_echo, chunks.items);
        return respondJson(request, .ok, response_body);
    }

    // 流式：chunked SSE 下行（缓冲按请求独立，避免并发流式请求互踩）
    var stream_buffer: [16384]u8 = undefined;
    var body_writer = try request.respondStreaming(&stream_buffer, .{
        .respond_options = .{
            .extra_headers = &.{.{ .name = "content-type", .value = "text/event-stream" }},
        },
    });
    // 响应头立刻发出：Zig 的 respondStreaming 只把响应头写进连接缓冲，不 flush。
    // 不先发头，客户端在等待上游首帧期间连 200 都看不到（header timeout 先于保活触发）。
    try http_util.flushBody(&body_writer);
    last_write_ms.store(clock.unixMilli(), .release);
    var stream_out = inbound_openai.StreamOut.init(arena, parsed.model_echo);
    watchdog_entry.stream_out = &stream_out;
    watchdog_entry.body = &body_writer;
    sink_stream_out = &stream_out;
    sink_body = &body_writer;
    sink_chunks = null;
    sink_arena = arena;
    sink_failure = null;
    sink_frames_sent = &frames_sent;
    var failure: ?openai.Failure = null;
    defer {
        sink_stream_out = null;
        sink_body = null;
        sink_arena = null;
        sink_frames_sent = null;
    }
    _ = router_mod.callHealed(arena, io, route_cache, registry.find(parsed.request.provider).?, .openai, parsed.request, &failure, {}, onChunkForward, &frames_sent) catch {
        // 上游失败：写 error 帧 + [DONE]（先置 finished，占位看门狗即停手）
        finished_flag.store(true, .release);
        const failure_value = failure orelse openai.Failure{ .status = 502, .code = "GATEWAY_FAILURE", .message = "upstream failed" };
        const frames = try inbound_openai.StreamOut.errorFrames(arena, failure_value.message, failure_value.code);
        client_mutex.lockUncancelable(io);
        defer client_mutex.unlock(io);
        for (frames) |frame| try body_writer.writer.writeAll(frame);
        try http_util.flushBody(&body_writer);
        try body_writer.end();
        return;
    };
    finished_flag.store(true, .release);
    const tail = try stream_out.doneFrames();
    client_mutex.lockUncancelable(io);
    defer client_mutex.unlock(io);
    for (tail) |frame| try body_writer.writer.writeAll(frame);
    try http_util.flushBody(&body_writer);
    try body_writer.end();
}

// ---------------------------------------------------------------------------
// Anthropic Messages 方言
// ---------------------------------------------------------------------------

threadlocal var sink_a_stream_out: ?*inbound_anthropic.StreamOut = null;
threadlocal var sink_a_chunks: ?*std.ArrayList(types.Chunk) = null;

fn onAnthropicChunkForward(_: void, chunk: types.Chunk) !void {
    if (sink_last_chunk_ms) |stamp| stamp.store(clock.unixMilli(), .release);
    if (sink_a_stream_out) |out| {
        const frames = try out.write(chunk);
        if (sink_body) |body_writer| {
            const mutex = sink_client_mutex orelse {
                for (frames) |frame| try body_writer.writer.writeAll(frame);
                if (frames.len > 0) {
                    try http_util.flushBody(body_writer);
                    if (sink_frames_sent) |flag| flag.* = true;
                }
                return;
            };
            mutex.lockUncancelable(sink_io.?);
            defer mutex.unlock(sink_io.?);
            for (frames) |frame| try body_writer.writer.writeAll(frame);
            if (frames.len > 0) {
                try http_util.flushBody(body_writer);
                if (sink_frames_sent) |flag| flag.* = true;
                if (sink_last_write_ms) |stamp| stamp.store(clock.unixMilli(), .release);
            }
        }
        return;
    }
    if (sink_a_chunks) |list| {
        const arena = sink_arena orelse return;
        try list.append(arena, chunk);
    }
}

fn handleAnthropic(
    arena: std.mem.Allocator,
    io: std.Io,
    request: *std.http.Server.Request,
    registry: *providers_mod.Registry,
    config: *const Config,
    route_cache: *router_mod.Cache,
) !void {
    _ = config;
    const body_text = try readBody(arena, request);
    const parsed_json = std.json.parseFromSliceLeaky(std.json.Value, arena, body_text, .{}) catch {
        return respondJsonError(request, .bad_request, "request body is not valid JSON", "INVALID_JSON");
    };
    if (parsed_json != .object) {
        return respondJsonError(request, .bad_request, "request body must be an object", "INVALID_JSON");
    }
    const parsed = inbound_anthropic.parse(arena, registry, parsed_json.object) catch |err| {
        diag.print("inbound parse failed: {s}\n", .{@errorName(err)});
        switch (err) {
        error.MissingModel => return respondJsonError(request, .bad_request, "missing \"model\"", "INVALID_REQUEST"),
        error.MissingMessages => return respondJsonError(request, .bad_request, "missing \"messages\"", "INVALID_REQUEST"),
        error.EmptyRequest => return respondJsonError(request, .bad_request, "no usable messages after normalization", "EMPTY_REQUEST"),
        error.UnknownModel => return respondJsonError(request, .bad_request, "unknown model; see GET /models", "UNKNOWN_MODEL"),
        error.AmbiguousModel => {
            diag.print("ambiguous model: {s}\n", .{modelEcho(parsed_json.object)});
            return respondAmbiguousModel(arena, request, registry, modelEcho(parsed_json.object));
        },
        else => return err,
        }
    };
    diag.print("inbound anthropic model={s} stream={d} msgs={d} system={d}B tools={d} max_tokens={d}\n", .{
        parsed.model_echo, @intFromBool(parsed.stream), parsed.request.messages.len,
        if (parsed.request.system) |system| system.len else 0,
        if (parsed.request.tools) |tools| tools.len else 0,
        parsed.request.max_tokens orelse 0,
    });
    const profile = registry.find(parsed.request.provider) orelse
        return respondJsonError(request, .bad_request, "unknown provider", "UNKNOWN_MODEL");

    // 看门狗注册（流式/非流式都注册；非流式 body=null 只做空闲超时）
    var frames_sent = false;
    var placeholder_sent = false;
    var finished_flag = std.atomic.Value(bool).init(false);
    var last_write_ms = std.atomic.Value(i64).init(clock.unixMilli());
    var last_chunk_ms = std.atomic.Value(i64).init(clock.unixMilli());
    var timed_out_flag = std.atomic.Value(bool).init(false);
    var client_mutex: std.Io.Mutex = .init;
    var watchdog_entry = watchdog_mod.Entry{
        .io = io,
        .dialect = .anthropic,
        .stream_out = null,
        .body = null,
        .mutex = &client_mutex,
        .placeholder_sent = &placeholder_sent,
        .last_write_ms = &last_write_ms,
        .finished = &finished_flag,
        .last_chunk_ms = &last_chunk_ms,
        .idle_timeout_ms = watchdog_mod.idleTimeoutMs(),
        .timed_out = &timed_out_flag,
    };
    watchdog_mod.register(&watchdog_entry);
    watchdog_mod.bindCurrent(&watchdog_entry);
    sink_client_mutex = &client_mutex;
    sink_last_write_ms = &last_write_ms;
    sink_last_chunk_ms = &last_chunk_ms;
    sink_io = io;
    defer {
        watchdog_mod.unregister(&watchdog_entry);
        watchdog_mod.unbindCurrent();
        sink_client_mutex = null;
        sink_last_write_ms = null;
        sink_last_chunk_ms = null;
        sink_io = null;
    }

    if (!parsed.stream) {
        var chunks: std.ArrayList(types.Chunk) = .empty;
        var failure: ?openai.Failure = null;
        sink_a_chunks = &chunks;
        sink_arena = arena;
        sink_a_stream_out = null;
        sink_body = null;
        sink_frames_sent = &frames_sent;
        defer {
            sink_a_chunks = null;
            sink_arena = null;
            sink_frames_sent = null;
        }
        _ = router_mod.callHealed(arena, io, route_cache, profile, .anthropic, parsed.request, &failure, {}, onAnthropicChunkForward, &frames_sent) catch {
            finished_flag.store(true, .release);
            const failure_value = failure orelse openai.Failure{ .status = 502, .code = "GATEWAY_FAILURE", .message = "upstream failed" };
            const envelope = try std.fmt.allocPrint(arena, "{{\"type\":\"error\",\"error\":{{\"type\":\"gateway_error\",\"message\":{f},\"code\":{f}}}}}", .{
                std.json.fmt(failure_value.message, .{}), std.json.fmt(failure_value.code, .{}),
            });
            return respondJson(request, .bad_gateway, envelope);
        };
        finished_flag.store(true, .release);
        const response_body = try inbound_anthropic.assembleMessage(arena, parsed.model_echo, chunks.items);
        return respondJson(request, .ok, response_body);
    }

    var stream_buffer: [16384]u8 = undefined;
    var body_writer = try request.respondStreaming(&stream_buffer, .{
        .respond_options = .{
            .extra_headers = &.{.{ .name = "content-type", .value = "text/event-stream" }},
        },
    });
    // 响应头立刻发出：Zig 的 respondStreaming 只把响应头写进连接缓冲，不 flush。
    // 不先发头，客户端在等待上游首帧期间连 200 都看不到（header timeout 先于保活触发）。
    try http_util.flushBody(&body_writer);
    last_write_ms.store(clock.unixMilli(), .release);
    var stream_out = inbound_anthropic.StreamOut.init(arena, parsed.model_echo);
    watchdog_entry.stream_out = &stream_out;
    watchdog_entry.body = &body_writer;
    sink_a_stream_out = &stream_out;
    sink_body = &body_writer;
    sink_arena = arena;
    sink_a_chunks = null;
    sink_frames_sent = &frames_sent;
    var failure: ?openai.Failure = null;
    defer {
        sink_a_stream_out = null;
        sink_body = null;
        sink_arena = null;
        sink_frames_sent = null;
    }
    _ = router_mod.callHealed(arena, io, route_cache, profile, .anthropic, parsed.request, &failure, {}, onAnthropicChunkForward, &frames_sent) catch {
        finished_flag.store(true, .release);
        const failure_value = failure orelse openai.Failure{ .status = 502, .code = "GATEWAY_FAILURE", .message = "upstream failed" };
        const error_frame = try std.fmt.allocPrint(arena, "event: error\ndata: {{\"type\":\"error\",\"error\":{{\"type\":\"gateway_error\",\"message\":{f},\"code\":{f}}}}}\n\n", .{
            std.json.fmt(failure_value.message, .{}), std.json.fmt(failure_value.code, .{}),
        });
        client_mutex.lockUncancelable(io);
        defer client_mutex.unlock(io);
        try body_writer.writer.writeAll(error_frame);
        try http_util.flushBody(&body_writer);
        try body_writer.end();
        return;
    };
    finished_flag.store(true, .release);
    const tail = try stream_out.doneEvents();
    client_mutex.lockUncancelable(io);
    defer client_mutex.unlock(io);
    for (tail) |frame| try body_writer.writer.writeAll(frame);
    try http_util.flushBody(&body_writer);
    try body_writer.end();
}

// ---------------------------------------------------------------------------
// OpenAI Responses 方言
// ---------------------------------------------------------------------------

threadlocal var sink_r_stream_out: ?*inbound_responses.StreamOut = null;
threadlocal var sink_r_chunks: ?*std.ArrayList(types.Chunk) = null;

fn onResponseChunkForward(_: void, chunk: types.Chunk) !void {
    if (sink_last_chunk_ms) |stamp| stamp.store(clock.unixMilli(), .release);
    if (sink_r_stream_out) |out| {
        const frames = try out.write(chunk);
        if (sink_body) |body_writer| {
            const mutex = sink_client_mutex orelse {
                for (frames) |frame| try body_writer.writer.writeAll(frame);
                if (frames.len > 0) {
                    try http_util.flushBody(body_writer);
                    if (sink_frames_sent) |flag| flag.* = true;
                }
                return;
            };
            mutex.lockUncancelable(sink_io.?);
            defer mutex.unlock(sink_io.?);
            for (frames) |frame| try body_writer.writer.writeAll(frame);
            if (frames.len > 0) {
                try http_util.flushBody(body_writer);
                if (sink_frames_sent) |flag| flag.* = true;
                if (sink_last_write_ms) |stamp| stamp.store(clock.unixMilli(), .release);
            }
        }
        return;
    }
    if (sink_r_chunks) |list| {
        const arena = sink_arena orelse return;
        try list.append(arena, chunk);
    }
}

fn handleResponses(
    arena: std.mem.Allocator,
    io: std.Io,
    request: *std.http.Server.Request,
    registry: *providers_mod.Registry,
    config: *const Config,
    route_cache: *router_mod.Cache,
) !void {
    _ = config;
    const body_text = try readBody(arena, request);
    const parsed_json = std.json.parseFromSliceLeaky(std.json.Value, arena, body_text, .{}) catch {
        return respondJsonError(request, .bad_request, "request body is not valid JSON", "INVALID_JSON");
    };
    if (parsed_json != .object) {
        return respondJsonError(request, .bad_request, "request body must be an object", "INVALID_JSON");
    }
    const parsed = inbound_responses.parse(arena, registry, parsed_json.object) catch |err| {
        diag.print("inbound parse failed: {s}\n", .{@errorName(err)});
        switch (err) {
        error.MissingModel => return respondJsonError(request, .bad_request, "missing \"model\"", "INVALID_REQUEST"),
        error.MissingInput => return respondJsonError(request, .bad_request, "missing \"input\"", "INVALID_REQUEST"),
        error.EmptyRequest => return respondJsonError(request, .bad_request, "no usable input after normalization", "EMPTY_REQUEST"),
        error.UnknownModel => return respondJsonError(request, .bad_request, "unknown model; see GET /models", "UNKNOWN_MODEL"),
        error.AmbiguousModel => {
            diag.print("ambiguous model: {s}\n", .{modelEcho(parsed_json.object)});
            return respondAmbiguousModel(arena, request, registry, modelEcho(parsed_json.object));
        },
        else => return err,
        }
    };
    diag.print("inbound responses model={s} stream={d} msgs={d} system={d}B tools={d} max_tokens={d}\n", .{
        parsed.model_echo, @intFromBool(parsed.stream), parsed.request.messages.len,
        if (parsed.request.system) |system| system.len else 0,
        if (parsed.request.tools) |tools| tools.len else 0,
        parsed.request.max_tokens orelse 0,
    });
    const profile = registry.find(parsed.request.provider) orelse
        return respondJsonError(request, .bad_request, "unknown provider", "UNKNOWN_MODEL");

    // 看门狗注册（流式/非流式都注册；非流式 body=null 只做空闲超时）
    var frames_sent = false;
    var placeholder_sent = false;
    var finished_flag = std.atomic.Value(bool).init(false);
    var last_write_ms = std.atomic.Value(i64).init(clock.unixMilli());
    var last_chunk_ms = std.atomic.Value(i64).init(clock.unixMilli());
    var timed_out_flag = std.atomic.Value(bool).init(false);
    var client_mutex: std.Io.Mutex = .init;
    var watchdog_entry = watchdog_mod.Entry{
        .io = io,
        .dialect = .responses,
        .stream_out = null,
        .body = null,
        .mutex = &client_mutex,
        .placeholder_sent = &placeholder_sent,
        .last_write_ms = &last_write_ms,
        .finished = &finished_flag,
        .last_chunk_ms = &last_chunk_ms,
        .idle_timeout_ms = watchdog_mod.idleTimeoutMs(),
        .timed_out = &timed_out_flag,
    };
    watchdog_mod.register(&watchdog_entry);
    watchdog_mod.bindCurrent(&watchdog_entry);
    sink_client_mutex = &client_mutex;
    sink_last_write_ms = &last_write_ms;
    sink_last_chunk_ms = &last_chunk_ms;
    sink_io = io;
    defer {
        watchdog_mod.unregister(&watchdog_entry);
        watchdog_mod.unbindCurrent();
        sink_client_mutex = null;
        sink_last_write_ms = null;
        sink_last_chunk_ms = null;
        sink_io = null;
    }

    if (!parsed.stream) {
        var chunks: std.ArrayList(types.Chunk) = .empty;
        var failure: ?openai.Failure = null;
        sink_r_chunks = &chunks;
        sink_arena = arena;
        sink_r_stream_out = null;
        sink_body = null;
        sink_frames_sent = &frames_sent;
        defer {
            sink_r_chunks = null;
            sink_arena = null;
            sink_frames_sent = null;
        }
        _ = router_mod.callHealed(arena, io, route_cache, profile, .responses, parsed.request, &failure, {}, onResponseChunkForward, &frames_sent) catch {
            finished_flag.store(true, .release);
            const failure_value = failure orelse openai.Failure{ .status = 502, .code = "GATEWAY_FAILURE", .message = "upstream failed" };
            // 非流式的失败走标准错误信封（{"error":{message,type,code}}）：
            // 流事件形状（type=response.failed）只属于 SSE，放进 HTTP 错误体会让客户端读不到 message。
            return respondJsonError(request, .bad_gateway, failure_value.message, failure_value.code);
        };
        finished_flag.store(true, .release);
        const response_body = try inbound_responses.assembleResponse(arena, parsed.model_echo, chunks.items);
        return respondJson(request, .ok, response_body);
    }

    var stream_buffer: [16384]u8 = undefined;
    var body_writer = try request.respondStreaming(&stream_buffer, .{
        .respond_options = .{
            .extra_headers = &.{.{ .name = "content-type", .value = "text/event-stream" }},
        },
    });
    // 响应头立刻发出：Zig 的 respondStreaming 只把响应头写进连接缓冲，不 flush。
    // 不先发头，客户端在等待上游首帧期间连 200 都看不到（header timeout 先于保活触发）。
    try http_util.flushBody(&body_writer);
    last_write_ms.store(clock.unixMilli(), .release);
    var stream_out = inbound_responses.StreamOut.init(arena, parsed.model_echo);
    watchdog_entry.stream_out = &stream_out;
    watchdog_entry.body = &body_writer;
    sink_r_stream_out = &stream_out;
    sink_body = &body_writer;
    sink_arena = arena;
    sink_r_chunks = null;
    sink_frames_sent = &frames_sent;
    var failure: ?openai.Failure = null;
    defer {
        sink_r_stream_out = null;
        sink_body = null;
        sink_arena = null;
        sink_frames_sent = null;
    }
    _ = router_mod.callHealed(arena, io, route_cache, profile, .responses, parsed.request, &failure, {}, onResponseChunkForward, &frames_sent) catch {
        finished_flag.store(true, .release);
        const failure_value = failure orelse openai.Failure{ .status = 502, .code = "GATEWAY_FAILURE", .message = "upstream failed" };
        // 规范失败事件（与中途失败同一实现）：完整 Response 对象 + status="failed" + error。
        const error_frame = try stream_out.failedEvent(failure_value.code, failure_value.message);
        client_mutex.lockUncancelable(io);
        defer client_mutex.unlock(io);
        try body_writer.writer.writeAll(error_frame);
        try http_util.flushBody(&body_writer);
        try body_writer.end();
        return;
    };
    finished_flag.store(true, .release);
    const tail = try stream_out.doneEvents();
    client_mutex.lockUncancelable(io);
    defer client_mutex.unlock(io);
    for (tail) |frame| try body_writer.writer.writeAll(frame);
    try http_util.flushBody(&body_writer);
    try body_writer.end();
}

fn handleCountTokens(arena: std.mem.Allocator, request: *std.http.Server.Request) !void {
    const body = try readBody(arena, request);
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{}) catch {
        return respondJsonError(request, .bad_request, "request body is not valid JSON", "INVALID_JSON");
    };
    if (parsed != .object) return respondJsonError(request, .bad_request, "request body must be an object", "INVALID_JSON");
    var characters: usize = 0;
    if (parsed.object.get("system")) |system| {
        if (system == .string) characters += system.string.len;
    }
    if (parsed.object.get("messages")) |messages| {
        if (messages == .array) {
            for (messages.array.items) |message| {
                if (message != .object) continue;
                const content = message.object.get("content") orelse continue;
                switch (content) {
                    .string => |text| characters += text.len,
                    .array => |parts| {
                        for (parts.items) |part| {
                            if (part != .object) continue;
                            const part_type = part.object.get("type") orelse continue;
                            if (part_type == .string and std.mem.eql(u8, part_type.string, "text")) {
                                if (part.object.get("text")) |text| {
                                    if (text == .string) characters += text.string.len;
                                }
                            } else {
                                characters += 64;
                            }
                        }
                    },
                    else => {},
                }
            }
        }
    }
    const tokens = @max(1, (characters + 3) / 4);
    const response = try std.fmt.allocPrint(arena, "{{\"input_tokens\":{d}}}", .{tokens});
    return respondJson(request, .ok, response);
}

pub fn readBody(arena: std.mem.Allocator, request: *std.http.Server.Request) ![]const u8 {
    const body_buffer = try arena.alloc(u8, 16384);
    var body_reader = request.readerExpectContinue(body_buffer) catch return error.RequestBodyTooLarge;
    const limited = try body_reader.allocRemaining(arena, .limited64(max_body_bytes));
    return limited;
}

test "ambiguousMessage: 列出候选并逐个给出 provider/model 建议" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const candidates = [_][]const u8{ "intern-ai", "custom-1" };
    const message = try ambiguousMessage(arena, "glm-5.3", &candidates);
    try std.testing.expectEqualStrings(
        "model \"glm-5.3\" exists in: intern-ai, custom-1; use \"provider/model\", e.g. \"intern-ai/glm-5.3\" or \"custom-1/glm-5.3\"",
        message,
    );

    // 三个候选也要可读（", " 分隔 + " or " 连接建议）
    const three = [_][]const u8{ "a", "b", "c" };
    try std.testing.expectEqualStrings(
        "model \"m1\" exists in: a, b, c; use \"provider/model\", e.g. \"a/m1\" or \"b/m1\" or \"c/m1\"",
        try ambiguousMessage(arena, "m1", &three),
    );
}

test "modelEcho: 只认字符串 model 键" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, "{\"model\":\"glm-5.3\",\"stream\":true}", .{});
    try std.testing.expectEqualStrings("glm-5.3", modelEcho(parsed.object));
    const missing = try std.json.parseFromSliceLeaky(std.json.Value, arena, "{\"stream\":true}", .{});
    try std.testing.expectEqualStrings("", modelEcho(missing.object));
    const wrong_type = try std.json.parseFromSliceLeaky(std.json.Value, arena, "{\"model\":42}", .{});
    try std.testing.expectEqualStrings("", modelEcho(wrong_type.object));
}
