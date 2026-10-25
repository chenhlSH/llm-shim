//! 闭环探针（TS probe.ts + detect.ts 的 Zig 移植）：
//! key/裸站点 进 → 路径发现 → 协议轮询 → 模型闭环验证 → 档位嗅探 → 固化条目。
const std = @import("std");
const types = @import("types.zig");
const providers_mod = @import("providers.zig");

pub const WireProtocol = enum { openai, anthropic, responses };

pub const DetectedModel = struct {
    id: []const u8,
    name: []const u8 = "",
    context_window: ?u64 = null,
    vision: bool = false,
    reasoning: bool = false,
    free: bool = false,
};

pub const Preset = struct {
    id: []const u8,
    display_name: []const u8,
    base_url: []const u8,
};

pub const PRESETS = [_]Preset{
    .{ .id = "siliconflow", .display_name = "SiliconFlow 硅基流动", .base_url = "https://api.siliconflow.cn/v1" },
    .{ .id = "openrouter", .display_name = "OpenRouter", .base_url = "https://openrouter.ai/api/v1" },
    .{ .id = "modelscope", .display_name = "ModelScope 魔搭推理", .base_url = "https://api-inference.modelscope.cn/v1" },
    .{ .id = "volcengine-ark", .display_name = "火山方舟", .base_url = "https://ark.cn-beijing.volces.com/api/v3" },
    .{ .id = "zhipu", .display_name = "智谱 BigModel", .base_url = "https://open.bigmodel.cn/api/paas/v4" },
};

pub fn findPreset(id: []const u8) ?*const Preset {
    for (&PRESETS) |*preset| {
        if (std.mem.eql(u8, preset.id, id)) return preset;
    }
    return null;
}

pub const Candidate = struct {
    name: []const u8,
    base_url: []const u8,
    preset: ?[]const u8 = null,
};

pub const Frozen = struct {
    name: []const u8,
    base_url: []const u8,
    api_key_env: []const u8,
    protocol: WireProtocol,
    preset: ?[]const u8 = null,
    verified_models: []const []const u8 = &.{},
    effort_accepted: ?bool = null,
};

pub const ProbeOptions = struct {
    verify_models: usize = 8,
    verify_paid: bool = false,
    no_verify: bool = false,
    include_presets: bool = true,
};

// ---------------------------------------------------------------------------
// HTTP 助手（探针用非流式整读）
// ---------------------------------------------------------------------------

pub const HttpResponse = struct {
    status: u16,
    body: []const u8,
};

fn requestOnce(
    arena: std.mem.Allocator,
    client: *std.http.Client,
    method: std.http.Method,
    url: []const u8,
    key: ?[]const u8,
    body: ?[]const u8,
) !HttpResponse {
    const bearer = if (key) |k| try std.fmt.allocPrint(arena, "Bearer {s}", .{k}) else null;
    // client.fetch：自动跟随重定向 + 解压（gzip/zstd/deflate）。低级
    // request/receiveHead 不解压——AMD 的 /models 会 gzip，裸读会导致 JSON 解析失败。
    var out: std.Io.Writer.Allocating = .init(arena);
    const result = try client.fetch(.{
        .location = .{ .url = url },
        .method = method,
        .payload = body,
        .headers = .{
            .authorization = if (bearer) |value| .{ .override = value } else .default,
            .content_type = .{ .override = "application/json" },
        },
        .response_writer = &out.writer,
    });
    return .{ .status = @intFromEnum(result.status), .body = out.written() };
}

// ---------------------------------------------------------------------------
// 路径自动发现（TS: resolveApiBase，含前缀回退修复）
// ---------------------------------------------------------------------------

pub const api_path_candidates = [_][]const u8{
    "",    "/v1",       "/v2",       "/v3",       "/v4",       "/api",  "/api/v1",
    "/api/v2", "/api/v3", "/api/v4", "/v1/openai", "/openai/v1", "/compatibility/v1",
    "/paas/v4", "/hf/v1", "/inference/v1",
};

const PathProbeVerdict = enum { list, auth_wall, miss };

fn modelsProbe(arena: std.mem.Allocator, client: *std.http.Client, base: []const u8, suffix: []const u8, key: ?[]const u8) PathProbeVerdict {
    const url = std.fmt.allocPrint(arena, "{s}{s}/models", .{ base, suffix }) catch return .miss;
    var attempt: usize = 0;
    while (attempt <= 2) : (attempt += 1) {
        const response = requestOnce(arena, client, .GET, url, key, null) catch return .miss;
        if (response.status == 429) {
            // 限流退避重试（不作为路径信号）
            @import("clock.zig").sleepMilli(1000);
            continue;
        }
        if (response.status == 401 or response.status == 403) {
            // 密钥墙必须是 JSON API 错误（WAF 的 HTML 拦截页不算）
            const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, response.body, .{}) catch return .miss;
            if (parsed != .object) return .miss;
            return .auth_wall;
        }
        if (response.status != 200) return .miss;
        const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, response.body, .{}) catch return .miss;
        if (parsed != .object and parsed != .array) return .miss;
        if (parsed == .object) {
            const data = parsed.object.get("data") orelse return .miss;
            if (data != .array) return .miss;
        }
        return .list;
    }
    return .miss;
}

fn routeProbe(arena: std.mem.Allocator, client: *std.http.Client, base: []const u8, suffix: []const u8, key: ?[]const u8) bool {
    const attempts = [_]struct { path: []const u8, body: []const u8 }{
        .{ .path = "/chat/completions", .body = "{\"model\":\"dsh-path-probe\",\"messages\":[]}" },
        .{ .path = "/responses", .body = "{\"model\":\"dsh-path-probe\",\"input\":\"ping\"}" },
        .{ .path = "/messages", .body = "{\"model\":\"dsh-path-probe\",\"max_tokens\":1,\"messages\":[]}" },
    };
    for (attempts) |attempt| {
        const url = std.fmt.allocPrint(arena, "{s}{s}{s}", .{ base, suffix, attempt.path }) catch continue;
        const response = requestOnce(arena, client, .POST, url, key, attempt.body) catch continue;
        // 404 = 路径不存在；429 = 限流不作为证据；
        // 其余非 404 须返回 JSON（WAF HTML 拦截页不算）才是"路由存在"。
        if (response.status == 429) continue;
        if (response.status == 404) continue;
        const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, response.body, .{}) catch continue;
        if (parsed != .object) continue;
        return true;
    }
    return false;
}

/// 路径自动发现（含前缀回退修复）：输入可以是裸站点或写错后缀的 URL。
/// 返回 null = 所有候选都未命中。
/// 运行时自愈用的"近邻后缀"子集：按 URL 形状优先试最常见的几种。
pub const quick_api_path_candidates = [_][]const u8{ "", "/v1", "/api/v1", "/v1/openai", "/paas/v4" };

pub const ResolveOptions = struct {
    /// 快速模式（网关运行时自愈）：只试近邻后缀子集 + 更短节流，预算数秒内。
    quick: bool = false,
};

pub fn resolveApiBase(
    arena: std.mem.Allocator,
    client: *std.http.Client,
    site: []const u8,
    key: ?[]const u8,
) !?[]const u8 {
    return resolveApiBaseWith(arena, client, site, key, .{});
}

pub fn resolveApiBaseWith(
    arena: std.mem.Allocator,
    client: *std.http.Client,
    site: []const u8,
    key: ?[]const u8,
    options: ResolveOptions,
) !?[]const u8 {
    const trimmed = std.mem.trimEnd(u8, site, "/");
    const parsed_url = std.Uri.parse(trimmed) catch return null;
    const origin = try std.fmt.allocPrint(arena, "{s}://{s}", .{ parsed_url.scheme, authorityOf(parsed_url) orelse return null });
    const segments = componentText(parsed_url.path);
    var parts: std.ArrayList([]const u8) = .empty;
    var iterator = std.mem.splitScalar(u8, segments, '/');
    while (iterator.next()) |segment| {
        if (segment.len > 0) try parts.append(arena, segment);
    }

    // 层级：完整路径 → 逐级剥短 → 根（长层优先）；quick 模式只保留最长两层
    const levels_limit: usize = if (options.quick) 2 else std.math.maxInt(usize);
    const suffix_list: []const []const u8 = if (options.quick) &quick_api_path_candidates else &api_path_candidates;
    const probe_gap_ms: u64 = if (options.quick) 120 else 300;
    var levels: std.ArrayList([]const u8) = .empty;
    var end = parts.items.len;
    while (true) {
        const level = try joinPath(arena, parts.items[0..end]);
        var duplicate = false;
        for (levels.items) |existing| {
            if (std.mem.eql(u8, existing, level)) duplicate = true;
        }
        if (!duplicate and levels.items.len < levels_limit) try levels.append(arena, level);
        if (end == 0) break;
        end -= 1;
    }

    var candidates: std.ArrayList(struct { level: []const u8, suffix: []const u8 }) = .empty;
    var pushed: std.StringHashMap(void) = .init(arena);
    for (levels.items) |level| {
        for (suffix_list) |suffix| {
            const combined = try std.fmt.allocPrint(arena, "/{s}{s}", .{ level, suffix });
            if (pushed.contains(combined)) continue;
            try pushed.put(combined, {});
            try candidates.append(arena, .{ .level = level, .suffix = suffix });
        }
    }

    // 第一轮：GET /models（目录或密钥墙都算命中）。level 自带前导 '/'（根为空）。
    // 命中后闭环验证（真实拉目录），失败继续扫——限流/WAF 误判自愈。
    // 每次探测间隔默认 300ms（quick 模式 120ms），避免触发 WAF/限流。
    for (candidates.items) |candidate| {
        @import("clock.zig").sleepMilli(probe_gap_ms);
        const base = try std.fmt.allocPrint(arena, "{s}{s}", .{ origin, candidate.level });
        const verdict = modelsProbe(arena, client, base, candidate.suffix, key);
        if (verdict == .list or verdict == .auth_wall) {
            const resolved = try std.fmt.allocPrint(arena, "{s}{s}", .{ base, candidate.suffix });
            if (verdict == .list) {
                if (detectModels(arena, client, resolved, key)) |_| {
                    return resolved;
                } else |_| {}
            } else {
                return resolved; // 密钥墙：目录拉不到但路由确凿
            }
        }
    }
    // 第二轮：POST 探路由（非 404 + JSON），命中后同样闭环验证
    for (candidates.items) |candidate| {
        const base = try std.fmt.allocPrint(arena, "{s}{s}", .{ origin, candidate.level });
        if (routeProbe(arena, client, base, candidate.suffix, key)) {
            const resolved = try std.fmt.allocPrint(arena, "{s}{s}", .{ base, candidate.suffix });
            if (detectModels(arena, client, resolved, key)) |_| {
                return resolved;
            } else |_| {}
        }
    }
    return null;
}

fn authorityOf(uri: std.Uri) ?[]const u8 {
    const host = uri.host orelse return null;
    const port = uri.port;
    if (port) |port_value| {
        if ((std.mem.eql(u8, uri.scheme, "http") and port_value != 80) or
            (std.mem.eql(u8, uri.scheme, "https") and port_value != 443))
        {
            // 带非默认端口：需保留
        } else {
            return switch (host) {
                .raw => |text| text,
                .percent_encoded => |text| text,
            };
        }
        return std.fmt.allocPrint(std.heap.page_allocator, "{s}:{d}", .{ componentText(host), port_value }) catch null;
    }
    return switch (host) {
        .raw => |text| text,
        .percent_encoded => |text| text,
    };
}

fn componentText(component: std.Uri.Component) []const u8 {
    return switch (component) {
        .raw => |text| text,
        .percent_encoded => |text| text,
    };
}

fn joinPath(arena: std.mem.Allocator, segments: []const []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (segments) |segment| {
        try out.append(arena, '/');
        try out.appendSlice(arena, segment);
    }
    return out.items;
}

// ---------------------------------------------------------------------------
// /models 目录探测（TS: detectProvider）
// ---------------------------------------------------------------------------

pub fn detectModels(
    arena: std.mem.Allocator,
    client: *std.http.Client,
    base_url: []const u8,
    key: ?[]const u8,
) ![]const DetectedModel {
    const url = try std.fmt.allocPrint(arena, "{s}/models", .{std.mem.trimEnd(u8, base_url, "/")});
    const response = try requestOnce(arena, client, .GET, url, key, null);
    if (response.status == 401 or response.status == 403) return error.AuthFailed;
    if (response.status != 200) return error.InvalidCatalog;
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, response.body, .{}) catch return error.InvalidCatalog;

    const list: []const std.json.Value = switch (parsed) {
        .array => |array| array.items,
        .object => |object| blk: {
            const data = object.get("data") orelse return error.InvalidCatalog;
            if (data != .array) return error.InvalidCatalog;
            break :blk data.array.items;
        },
        else => return error.InvalidCatalog,
    };

    var models: std.ArrayList(DetectedModel) = .empty;
    for (list) |raw| {
        if (raw != .object) continue;
        const object = raw.object;
        const id = if (object.get("id")) |value| (if (value == .string) value.string else "") else "";
        if (id.len == 0) continue;
        var model = DetectedModel{ .id = id };
        if (object.get("name")) |value| {
            if (value == .string and value.string.len > 0) model.name = value.string;
        }
        if (object.get("context_length")) |value| {
            if (value == .integer and value.integer > 0) {
                model.context_window = @intCast(value.integer);
            }
        } else if (object.get("contextWindow")) |value| {
            if (value == .integer and value.integer > 0) {
                model.context_window = @intCast(value.integer);
            }
        }
        var modalities: std.ArrayList([]const u8) = .empty;
        if (object.get("input_modalities")) |value| {
            if (value == .array) {
                for (value.array.items) |entry| {
                    if (entry == .string) try modalities.append(arena, entry.string);
                }
            }
        }
        for (modalities.items) |modality| {
            if (std.mem.eql(u8, modality, "image")) model.vision = true;
        }
        if (object.get("supported_parameters")) |value| {
            if (value == .array) {
                for (value.array.items) |entry| {
                    if (entry == .string and std.mem.eql(u8, entry.string, "reasoning")) model.reasoning = true;
                }
            }
        }
        if (!model.reasoning) {
            const patterns = [_][]const u8{ "deepseek-r", "reasoning", "thinking", "r1", "o1", "o3", "qwq" };
            var id_buffer: [512]u8 = undefined;
            const lower = lowerInto(&id_buffer, id);
            for (patterns) |pattern| {
                if (std.mem.indexOf(u8, lower, pattern) != null) model.reasoning = true;
            }
        }
        if (object.get("pricing")) |pricing| {
            if (pricing == .object) {
                for ([_][]const u8{ "prompt", "completion", "cost_usd" }) |key_name| {
                    if (pricing.object.get(key_name)) |value| {
                        const number: ?f64 = switch (value) {
                            .float => |float| float,
                            .integer => |int| @floatFromInt(int),
                            .string => |text| std.fmt.parseFloat(f64, text) catch null,
                            else => null,
                        };
                        if (number) |zero_check| {
                            if (zero_check == 0) model.free = true;
                        }
                    }
                }
            }
        }
        try models.append(arena, model);
    }
    if (models.items.len == 0) return error.InvalidCatalog;
    return models.items;
}

fn lowerInto(buffer: []u8, text: []const u8) []const u8 {
    const n = @min(buffer.len, text.len);
    for (text[0..n], 0..) |byte, index| buffer[index] = std.ascii.toLower(byte);
    return buffer[0..n];
}

// ---------------------------------------------------------------------------
// 协议轮询 + 闭环验证 + key-first 循环（TS: probeProtocol / verifyModels / probeKey）
// ---------------------------------------------------------------------------

pub const Protocol = WireProtocol;

fn pingChat(arena: std.mem.Allocator, client: *std.http.Client, base_url: []const u8, key: []const u8, model: []const u8) !u16 {
    return pingChatEffort(arena, client, base_url, key, model, null);
}

fn pingChatEffort(arena: std.mem.Allocator, client: *std.http.Client, base_url: []const u8, key: []const u8, model: []const u8, effort: ?[]const u8) !u16 {
    const url = try std.fmt.allocPrint(arena, "{s}/chat/completions", .{std.mem.trimEnd(u8, base_url, "/")});
    const effort_json = if (effort) |value| try std.fmt.allocPrint(arena, ",\"reasoning_effort\":{f}", .{std.json.fmt(value, .{})}) else "";
    const body = try std.fmt.allocPrint(arena, "{{\"model\":{f},\"max_tokens\":1,\"messages\":[{{\"role\":\"user\",\"content\":\"ping\"}}]{s}}}", .{ std.json.fmt(model, .{}), effort_json });
    const response = try requestOnce(arena, client, .POST, url, key, body);
    return response.status;
}

fn pingAnthropic(arena: std.mem.Allocator, client: *std.http.Client, base_url: []const u8, key: []const u8, model: []const u8) !u16 {
    const url = try std.fmt.allocPrint(arena, "{s}/messages", .{std.mem.trimEnd(u8, base_url, "/")});
    const body = try std.fmt.allocPrint(arena, "{{\"model\":{f},\"max_tokens\":1,\"messages\":[{{\"role\":\"user\",\"content\":\"ping\"}}]}}", .{std.json.fmt(model, .{})});
    var req = try client.request(.POST, try std.Uri.parse(url), .{
        .headers = .{ .content_type = .{ .override = "application/json" } },
        .extra_headers = &.{
            .{ .name = "x-api-key", .value = key },
            .{ .name = "anthropic-version", .value = "2023-06-01" },
            .{ .name = "authorization", .value = try std.fmt.allocPrint(arena, "Bearer {s}", .{key}) },
        },
    });
    defer req.deinit();
    try req.sendBodyComplete(@constCast(body));
    var redirect_buffer: [8192]u8 = undefined;
    const response = try req.receiveHead(&redirect_buffer);
    return @intFromEnum(response.head.status);
}

fn pingResponses(arena: std.mem.Allocator, client: *std.http.Client, base_url: []const u8, key: []const u8, model: []const u8) !u16 {
    const url = try std.fmt.allocPrint(arena, "{s}/responses", .{std.mem.trimEnd(u8, base_url, "/")});
    const body = try std.fmt.allocPrint(arena, "{{\"model\":{f},\"input\":\"ping\",\"max_output_tokens\":16,\"stream\":false,\"store\":false}}", .{std.json.fmt(model, .{})});
    const response = try requestOnce(arena, client, .POST, url, key, body);
    return response.status;
}

/// 协议轮询：OpenAI → Anthropic → Responses 顺序各探一次。
pub fn probeProtocol(
    arena: std.mem.Allocator,
    client: *std.http.Client,
    base_url: []const u8,
    key: []const u8,
    model: []const u8,
) !?WireProtocol {
    if ((try pingChat(arena, client, base_url, key, model)) == 200) return .openai;
    if ((try pingAnthropic(arena, client, base_url, key, model)) == 200) return .anthropic;
    if ((try pingResponses(arena, client, base_url, key, model)) == 200) return .responses;
    return null;
}

/// 协议轮询加强版：目录前几个模型逐个试（野生目录首位可能是非对话模型）。
pub fn probeProtocolMulti(
    arena: std.mem.Allocator,
    client: *std.http.Client,
    base_url: []const u8,
    key: []const u8,
    models: []const DetectedModel,
) !?WireProtocol {
    const try_count = @min(models.len, 4);
    var index: usize = 0;
    while (index < try_count) : (index += 1) {
        const model = models[index];
        if ((try pingChat(arena, client, base_url, key, model.id)) == 200) return .openai;
        if ((try pingAnthropic(arena, client, base_url, key, model.id)) == 200) return .anthropic;
        if ((try pingResponses(arena, client, base_url, key, model.id)) == 200) return .responses;
    }
    return null;
}

pub const VerifyResult = struct {
    verified: []const []const u8,
    stopped_early: bool,
};

/// 模型闭环验证：真实最小请求，免费模型优先，连续 429 熔断。
pub fn verifyModels(
    arena: std.mem.Allocator,
    client: *std.http.Client,
    base_url: []const u8,
    key: []const u8,
    candidates: []const DetectedModel,
    limit: usize,
    verify_paid: bool,
) VerifyResult {
    var verified: std.ArrayList([]const u8) = .empty;
    var consecutive_429: usize = 0;
    var stopped_early = false;
    for (candidates) |model| {
        if (verified.items.len >= limit) break;
        if (!verify_paid and !model.free and verified.items.len > 0) continue;
        const status = pingChat(arena, client, base_url, key, model.id) catch {
            consecutive_429 += 1;
            if (consecutive_429 >= 2) {
                stopped_early = true;
                break;
            }
            continue;
        };
        if (status == 200) {
            verified.append(arena, model.id) catch {};
            consecutive_429 = 0;
        } else if (status == 429) {
            consecutive_429 += 1;
            if (consecutive_429 >= 2) {
                stopped_early = true;
                break;
            }
        }
    }
    return .{ .verified = verified.items, .stopped_early = stopped_early };
}

pub const EndpointProbe = struct {
    candidate_name: []const u8,
    base_url: []const u8,
    preset: ?[]const u8,
    protocol: WireProtocol,
    model_count: usize,
    verified_models: []const []const u8,
    effort_accepted: ?bool,
    /// 验证因连续 429（限流熔断）提前结束——模型清单未验完，不代表其余模型不可用。
    stopped_early: bool = false,
    frozen: Frozen,
};

/// 单端点探针：key 可用 → 协议 → 验证 → 档位嗅探 → 固化条目。
pub fn probeEndpoint(
    arena: std.mem.Allocator,
    client: *std.http.Client,
    candidate: Candidate,
    key: []const u8,
    api_key_env: []const u8,
    options: ProbeOptions,
) !?EndpointProbe {
    const debug = @import("env.zig").get("AUTO_COMPAT_DEBUG") != null;
    if (debug) std.debug.print("[probe] {s}: discovering path...\n", .{candidate.base_url});
    // 路径自动发现：candidate.base_url 允许是裸站点
    const resolved_base = (try resolveApiBase(arena, client, candidate.base_url, key)) orelse {
        if (debug) std.debug.print("[probe] {s}: no API path found\n", .{candidate.base_url});
        return null;
    };
    if (debug) std.debug.print("[probe] {s}: resolved base {s}\n", .{ candidate.base_url, resolved_base });
    const models = try detectModels(arena, client, resolved_base, key);
    if (debug) std.debug.print("[probe] {s}: {d} models, first={s}\n", .{ resolved_base, models.len, models[0].id });
    const first_model = models[0];
    const protocol = (try probeProtocolMulti(arena, client, resolved_base, key, models)) orelse {
        if (debug) std.debug.print("[probe] {s}: no dialect matched\n", .{resolved_base});
        return null;
    };
    if (debug) std.debug.print("[probe] {s}: dialect={s}\n", .{ resolved_base, @tagName(protocol) });

    var verified: []const []const u8 = &.{};
    var stopped_early = false;
    if (!options.no_verify and protocol == .openai) {
        var pool: std.ArrayList(DetectedModel) = .empty;
        for (models) |model| {
            if (options.verify_paid or model.free or std.mem.eql(u8, model.id, first_model.id)) {
                try pool.append(arena, model);
            }
        }
        if (pool.items.len == 0) try pool.append(arena, first_model);
        const limit = options.verify_models;
        const result = verifyModels(arena, client, resolved_base, key, pool.items, limit, options.verify_paid);
        verified = result.verified;
        stopped_early = result.stopped_early;
        if (stopped_early) {
            std.debug.print("[probe] {s}: 429 circuit-breaker, verification stopped early ({d} verified)\n", .{ resolved_base, verified.len });
        }
    }

    // 档位嗅探（openai 方言且已有验证模型时）：带 reasoning_effort 的请求 200 = 接受。
    var effort_accepted: ?bool = null;
    if (protocol == .openai and verified.len > 0) {
        const with_status = pingChatEffort(arena, client, resolved_base, key, verified[0], "low") catch 0;
        const without_status = pingChat(arena, client, resolved_base, key, verified[0]) catch 0;
        effort_accepted = if (with_status == 200) true else if (without_status == 200) false else null;
    }

    return EndpointProbe{
        .candidate_name = candidate.name,
        .base_url = resolved_base,
        .preset = candidate.preset,
        .protocol = protocol,
        .model_count = models.len,
        .verified_models = verified,
        .effort_accepted = effort_accepted,
        .stopped_early = stopped_early,
        .frozen = .{
            .name = candidate.name,
            .base_url = resolved_base,
            .api_key_env = api_key_env,
            .protocol = protocol,
            .preset = candidate.preset,
            .verified_models = verified,
            .effort_accepted = effort_accepted,
        },
    };
}

/// key-first 循环：key 找家（用户 URL + 内置厂商 + 预设）。
/// - 用户显式给的 URL 全部试探（支持一次固化多家）；
/// - 内置/预设是"猜"：任一端点命中后即停，不再轮询其余候选（每个端点的路径发现
///   要 15 后缀 × 300ms 节流，是探针耗时的主因）；
/// - 用户 URL 命中的端点若与带名候选（内置厂商/预设）相同，按该名字固化——否则
///   custom-N 会被装载期"内置优先"的同端点去重冷落，验证结果丢失。
pub fn probeKey(
    arena: std.mem.Allocator,
    client: *std.http.Client,
    key: []const u8,
    api_key_env: []const u8,
    extra_candidates: []const Candidate,
    options: ProbeOptions,
) ![]EndpointProbe {
    // 内置厂商 + 预设（"带名"名单）：既参与 key 找家，也作为用户 URL 命中时的改名目标。
    var named: std.ArrayList(Candidate) = .empty;
    if (options.include_presets) {
        try named.append(arena, .{ .name = "intern-ai", .base_url = "https://discovery-api.intern-ai.org.cn/v1", .preset = "intern-ai" });
        try named.append(arena, .{ .name = "amd-radeon", .base_url = "https://developer.amd.com.cn/radeon/api/v1", .preset = "amd-radeon" });
        for (&PRESETS) |*preset| {
            try named.append(arena, .{ .name = preset.id, .base_url = preset.base_url, .preset = preset.id });
        }
    }

    var candidates: std.ArrayList(Candidate) = .empty;
    var seen: std.StringHashMap(void) = .init(arena);
    const appendCandidate = struct {
        fn run(list: *std.ArrayList(Candidate), seen_map: *std.StringHashMap(void), a: std.mem.Allocator, candidate: Candidate) !void {
            const normalized = try std.fmt.allocPrint(a, "{s}", .{std.mem.trimEnd(u8, candidate.base_url, "/")});
            if (seen_map.contains(normalized)) return;
            try seen_map.put(normalized, {});
            try list.append(a, candidate);
        }
    }.run;
    for (extra_candidates) |candidate| try appendCandidate(&candidates, &seen, arena, candidate);
    for (named.items) |candidate| try appendCandidate(&candidates, &seen, arena, candidate);

    var results: std.ArrayList(EndpointProbe) = .empty;
    var matched_endpoints: std.ArrayList([]const u8) = .empty;
    for (candidates.items) |candidate| {
        if (!shouldPollCandidate(candidate, matched_endpoints.items.len)) break; // 已命中：预设不再白试
        const result = probeEndpoint(arena, client, candidate, key, api_key_env, options) catch null;
        var value = result orelse continue;

        if (candidate.preset == null) {
            if (relabelToNamedCandidate(named.items, value.base_url)) |named_hit| {
                value.candidate_name = named_hit.name;
                value.preset = named_hit.preset;
                value.frozen.name = named_hit.name;
                value.frozen.preset = named_hit.preset;
            }
        }

        // 同端点只固化一条（多个用户 URL 解析到同一端点时）
        var duplicate = false;
        for (matched_endpoints.items) |endpoint| {
            if (providers_mod.sameEndpoint(endpoint, value.base_url)) duplicate = true;
        }
        if (duplicate) continue;
        try matched_endpoints.append(arena, try std.fmt.allocPrint(arena, "{s}", .{value.base_url}));
        try results.append(arena, value);
    }
    return results.items;
}

/// 轮询决策（纯函数）：用户显式给的 URL（无 preset）永远试探；内置/预设是"猜"，
/// 一旦已有命中就不再白试。抽出便于单测锁定"命中即停"语义。
fn shouldPollCandidate(candidate: Candidate, matched_count: usize) bool {
    return candidate.preset == null or matched_count == 0;
}

/// 用户 URL（无 preset）解析出的端点与某个带 preset 的候选端点相同时，返回该候选
/// （冻结条目改用它的名字与 preset 固化）。纯函数，便于单测。
fn relabelToNamedCandidate(named: []const Candidate, resolved_base: []const u8) ?Candidate {
    for (named) |candidate| {
        if (candidate.preset == null) continue;
        if (providers_mod.sameEndpoint(candidate.base_url, resolved_base)) return candidate;
    }
    return null;
}

test "relabelToNamedCandidate: 用户 URL 命中带 preset 的端点则按该名字固化" {
    const named = [_]Candidate{
        .{ .name = "intern-ai", .base_url = "https://discovery-api.intern-ai.org.cn/v1", .preset = "intern-ai" },
        .{ .name = "amd-radeon", .base_url = "https://developer.amd.com.cn/radeon/api/v1", .preset = "amd-radeon" },
    };
    // 裸站点解析到内置端点（尾斜杠/大小写归一化）→ 改名目标
    const hit = relabelToNamedCandidate(&named, "HTTPS://discovery-api.intern-ai.org.cn/v1/").?;
    try std.testing.expectEqualStrings("intern-ai", hit.name);
    try std.testing.expectEqualStrings("intern-ai", hit.preset.?);
    // 无 preset 的候选不参与改名
    const with_custom = named ++ [_]Candidate{.{ .name = "custom-1", .base_url = "https://other.example/v1" }};
    try std.testing.expect(relabelToNamedCandidate(&with_custom, "https://other.example/v1") == null);
    // 不同端点不改名
    try std.testing.expect(relabelToNamedCandidate(&named, "https://unrelated.example/api/v1") == null);
}

test "shouldPollCandidate: 命中即停只作用于带 preset 的候选" {
    const user_url = Candidate{ .name = "custom-1", .base_url = "http://127.0.0.1:1" };
    const preset = Candidate{ .name = "intern-ai", .base_url = "https://discovery-api.intern-ai.org.cn/v1", .preset = "intern-ai" };

    // 未命中：两类候选都要试
    try std.testing.expect(shouldPollCandidate(user_url, 0));
    try std.testing.expect(shouldPollCandidate(preset, 0));
    // 已有命中：用户 URL 继续试探（支持一次固化多家），预设/内置不再轮询
    try std.testing.expect(shouldPollCandidate(user_url, 1));
    try std.testing.expect(shouldPollCandidate(user_url, 3));
    try std.testing.expect(!shouldPollCandidate(preset, 1));
    try std.testing.expect(!shouldPollCandidate(preset, 3));
}
