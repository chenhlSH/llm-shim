//! OpenAI Chat Completions 上游适配器：dsh IR → chat wire，SSE → Chunk。
const std = @import("std");
const types = @import("../types.zig");
const effort_mod = @import("../effort.zig");
const providers_mod = @import("../providers.zig");
const env = @import("../env.zig");
const http_util = @import("../http_util.zig");
const watchdog_mod = @import("../watchdog.zig");
const client_key = @import("../client_key.zig");
const version_mod = @import("../version.zig");

pub const Failure = struct {
    status: u16,
    code: []const u8,
    message: []const u8,
    /// 429 的上游 Retry-After（毫秒），运行时自愈按它精确等待。
    retry_after_ms: ?u64 = null,
};

/// 从响应头解析 Retry-After（秒）。
pub fn retryAfterMs(head: std.http.Client.Response.Head) ?u64 {
    var iterator = head.iterateHeaders();
    while (iterator.next()) |header| {
        if (!std.ascii.eqlIgnoreCase(header.name, "retry-after")) continue;
        const seconds = std.fmt.parseInt(u64, std.mem.trim(u8, header.value, " \t"), 10) catch return null;
        return seconds * 1000;
    }
    return null;
}

/// 上游请求执行环境（client 复用连接池）。
pub const Client = struct {
    io: std.Io,
    http: std.http.Client,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) Client {
        return .{ .io = io, .http = .{ .allocator = allocator, .io = io } };
    }

    pub fn deinit(self: *Client) void {
        self.http.deinit();
    }
};

/// 匹配扫描结果：精确（模型 id 相等）优先，别名（大小写不敏感）兜底。
/// 计数按**供应商**（剖面）算：同一剖面里重复出现的 id/别名只算一次（与 TS routeModel 的
/// `providers.filter(...)` 语义一致），歧义只可能来自多个供应商。
const MatchScan = struct {
    exact_profile: ?*const providers_mod.Profile = null,
    exact_count: usize = 0,
    alias_profile: ?*const providers_mod.Profile = null,
    alias_model: []const u8 = "",
    alias_count: usize = 0,
};

fn scanMatches(registry: *providers_mod.Registry, model: []const u8) MatchScan {
    var scan: MatchScan = .{};
    for (registry.profiles.items) |*profile| {
        if (profileHasModel(profile, model)) {
            if (scan.exact_profile == null) scan.exact_profile = profile;
            scan.exact_count += 1;
        }
        for (profile.aliases) |alias| {
            if (!std.ascii.eqlIgnoreCase(alias.from, model)) continue;
            if (scan.alias_profile == null) {
                scan.alias_profile = profile;
                scan.alias_model = alias.to;
            }
            scan.alias_count += 1;
            break;
        }
    }
    return scan;
}

fn profileHasModel(profile: *const providers_mod.Profile, model: []const u8) bool {
    for (profile.models) |candidate| {
        if (std.mem.eql(u8, candidate.id, model)) return true;
    }
    return false;
}

fn profileHasAlias(profile: *const providers_mod.Profile, model: []const u8) bool {
    for (profile.aliases) |alias| {
        if (std.ascii.eqlIgnoreCase(alias.from, model)) return true;
    }
    return false;
}

/// 供应商解析（TS: routeModel）。返回命中的剖面与线上的模型 id。
pub fn resolveProvider(registry: *providers_mod.Registry, model: []const u8) !struct { profile: *const providers_mod.Profile, model: []const u8 } {
    if (std.mem.indexOfScalar(u8, model, '/')) |slash| {
        if (slash > 0) {
            const provider_name = model[0..slash];
            const rest = model[slash + 1 ..];
            if (registry.find(provider_name)) |profile| {
                var wire_model = rest;
                for (profile.aliases) |alias| {
                    if (std.ascii.eqlIgnoreCase(alias.from, rest)) wire_model = alias.to;
                }
                return .{ .profile = profile, .model = wire_model };
            }
        }
    }
    const scan = scanMatches(registry, model);
    if (scan.exact_count == 1) {
        const profile = scan.exact_profile.?;
        var wire_model = model;
        for (profile.aliases) |alias| {
            if (std.ascii.eqlIgnoreCase(alias.from, model)) wire_model = alias.to;
        }
        return .{ .profile = profile, .model = wire_model };
    }
    if (scan.alias_count == 1) return .{ .profile = scan.alias_profile.?, .model = scan.alias_model };
    if (scan.exact_count > 1 or scan.alias_count > 1) return error.AmbiguousModel;
    return error.UnknownModel;
}

/// 歧义诊断（网关 400 用）：`model` 同时命中多个供应商时返回候选名单（按注册顺序，
/// 内置在前）；无歧义/未命中返回空。判定与 resolveProvider 同源（scanMatches），
/// 因此与它报 AmbiguousModel 的条件严格一致。
pub fn ambiguousCandidates(
    arena: std.mem.Allocator,
    registry: *providers_mod.Registry,
    model: []const u8,
) ![]const []const u8 {
    const scan = scanMatches(registry, model);
    const by_exact = scan.exact_count > 1;
    const by_alias = !by_exact and scan.exact_count == 0 and scan.alias_count > 1;
    if (!by_exact and !by_alias) return &.{};
    var names: std.ArrayList([]const u8) = .empty;
    for (registry.profiles.items) |*profile| {
        const hit = if (by_exact) profileHasModel(profile, model) else profileHasAlias(profile, model);
        if (hit) try names.append(arena, profile.name);
    }
    return names.toOwnedSlice(arena);
}

fn wireModelId(profile: *const providers_mod.Profile, model: []const u8) []const u8 {
    for (profile.aliases) |alias| {
        if (std.ascii.eqlIgnoreCase(alias.from, model)) return alias.to;
    }
    return model;
}

fn modelSupportsVision(profile: *const providers_mod.Profile, model: []const u8) bool {
    const wire_id = wireModelId(profile, model);
    for (profile.models) |candidate| {
        if (std.mem.eql(u8, candidate.id, wire_id)) return candidate.vision;
    }
    return false;
}

const placeholder = "[图片已省略：当前模型不支持视觉输入]";

fn appendJsonPart(arena: std.mem.Allocator, parts: *std.ArrayList(u8), part: []const u8) !void {
    if (parts.items.len > 0) try parts.append(arena, ',');
    try parts.appendSlice(arena, part);
}

/// 消息投影：IR → OpenAI chat messages JSON 数组文本（含全部屏蔽规则）。
pub fn serializeMessages(
    arena: std.mem.Allocator,
    profile: *const providers_mod.Profile,
    model: []const u8,
    request: types.GenerateRequest,
) ![]const u8 {
    const vision = modelSupportsVision(profile, model);
    var out: std.Io.Writer.Allocating = .init(arena);
    const w = &out.writer;
    try w.writeAll("[");

    var first_message = true;
    if (request.system) |system| {
        if (system.len > 0) {
            try w.print("{{\"role\":\"system\",\"content\":{f}}}", .{std.json.fmt(system, .{})});
            first_message = false;
        }
    }
    for (request.messages) |message| {
        switch (message.role) {
            .user => {
                var parts: std.ArrayList(u8) = .empty;
                var has_image = false;
                var has_text = false;
                for (message.blocks) |block| {
                    switch (block) {
                        .text => |text| {
                            if (text.len == 0) continue;
                            has_text = true;
                            const part = try std.fmt.allocPrint(arena, "{{\"type\":\"text\",\"text\":{f}}}", .{std.json.fmt(text, .{})});
                            try appendJsonPart(arena, &parts, part);
                        },
                        .image => |image| {
                            has_image = true;
                            if (vision) {
                                const part = try std.fmt.allocPrint(arena, "{{\"type\":\"image_url\",\"image_url\":{{\"url\":{f}}}}}", .{std.json.fmt(image.data_uri, .{})});
                                try appendJsonPart(arena, &parts, part);
                            } else {
                                const part = try std.fmt.allocPrint(arena, "{{\"type\":\"text\",\"text\":{f}}}", .{std.json.fmt(placeholder, .{})});
                                try appendJsonPart(arena, &parts, part);
                            }
                        },
                        .reasoning, .tool_call => {},
                    }
                }
                if (!has_image and !has_text) continue; // 空消息跳过
                if (!first_message) try w.writeAll(",");
                first_message = false;
                try w.writeAll("{\"role\":\"user\",\"content\":[");
                try w.writeAll(parts.items);
                try w.writeAll("]}");
            },
            .assistant => {
                var tool_calls: std.ArrayList(u8) = .empty;
                var text: std.ArrayList(u8) = .empty;
                var has_tool = false;
                for (message.blocks) |block| {
                    switch (block) {
                        .text => |text_block| {
                            if (text_block.len > 0) {
                                if (text.items.len > 0) try text.append(arena, '\n');
                                try text.appendSlice(arena, text_block);
                            }
                        },
                        .tool_call => |call| {
                            has_tool = true;
                            const entry = try std.fmt.allocPrint(arena, "{{\"id\":{f},\"type\":\"function\",\"function\":{{\"name\":{f},\"arguments\":{f}}}}}", .{
                                std.json.fmt(call.id, .{}),
                                std.json.fmt(call.name, .{}),
                                std.json.fmt(call.arguments, .{}),
                            });
                            if (tool_calls.items.len > 0) try tool_calls.append(arena, ',');
                            try tool_calls.appendSlice(arena, entry);
                        },
                        .reasoning, .image => {},
                    }
                }
                if (has_tool) {
                    if (!first_message) try w.writeAll(",");
                    first_message = false;
                    if (text.items.len > 0) {
                        try w.print("{{\"role\":\"assistant\",\"content\":{f},\"tool_calls\":[{s}]}}", .{ std.json.fmt(text.items, .{}), tool_calls.items });
                    } else {
                        try w.print("{{\"role\":\"assistant\",\"content\":null,\"tool_calls\":[{s}]}}", .{tool_calls.items});
                    }
                } else if (text.items.len > 0) {
                    if (!first_message) try w.writeAll(",");
                    first_message = false;
                    try w.print("{{\"role\":\"assistant\",\"content\":{f}}}", .{std.json.fmt(text.items, .{})});
                }
            },
            .system, .tool => {}, // 已在入口归一
        }
    }
    try w.writeAll("]");
    return out.written();
}

/// 请求体序列化（TS: openai-compat stream() 的 body 构造）。
pub fn serializeBody(
    arena: std.mem.Allocator,
    profile: *const providers_mod.Profile,
    request: types.GenerateRequest,
) ![]const u8 {
    const model = request.model;
    var out: std.Io.Writer.Allocating = .init(arena);
    const w = &out.writer;
    try w.print("{{\"model\":{f},\"messages\":", .{std.json.fmt(model, .{})});
    try w.writeAll(try serializeMessages(arena, profile, model, request));
    try w.writeAll(",\"stream\":true,\"stream_options\":{\"include_usage\":true}");

    if (request.reasoning_effort) |effort| {
        if (effort_mod.mapEffort(profile.effort_strategy, model, effort)) |vendor_effort| {
            switch (profile.effort_wire) {
                .reasoning_effort => try w.print(",\"reasoning_effort\":{f}", .{std.json.fmt(vendor_effort, .{})}),
                .reasoning => try w.print(",\"reasoning\":{{\"effort\":{f}}}", .{std.json.fmt(vendor_effort, .{})}),
            }
        }
    }
    if (request.tools) |tools| {
        if (tools.len > 0) {
            try w.writeAll(",\"tools\":[");
            for (tools, 0..) |tool, index| {
                if (index > 0) try w.writeAll(",");
                try w.print("{{\"type\":\"function\",\"function\":{{\"name\":{f},\"description\":{f},\"parameters\":{f}}}}}", .{
                    std.json.fmt(tool.name, .{}),
                    std.json.fmt(tool.description, .{}),
                    std.json.fmt(tool.parameters, .{}),
                });
            }
            try w.writeAll("]");
        }
    }
    if (request.temperature) |temperature| {
        try w.print(",\"temperature\":{d}", .{temperature});
    }
    if (request.max_tokens) |max_tokens| {
        try w.print(",\"max_tokens\":{d}", .{max_tokens});
    }
    if (request.stop) |stop| {
        // AMD 白名单静默丢弃 → honors_stop=false 时不发（不承诺停止语义）。
        if (profile.honors_stop and stop.len > 0) {
            try w.writeAll(",\"stop\":");
            try std.json.Stringify.value(stop, .{}, w);
        }
    }
    try w.writeAll("}");
    return out.written();
}

// ---------------------------------------------------------------------------
// SSE → Chunk 翻译状态机（TS: chunks.ts 的 OpenAiStreamTranslator）
// ---------------------------------------------------------------------------

const OpenBlock = struct {
    kind: types.BlockKind,
    index: usize,
    text: std.ArrayList(u8),
    tool_id: []const u8,
    tool_name: std.ArrayList(u8),
};

pub const Translator = struct {
    arena: std.mem.Allocator,
    pkg: []const u8,
    reasoning_fields: []const []const u8,
    next_index: usize = 0,
    open: std.ArrayList(*OpenBlock) = .empty,
    tool_buckets: std.AutoHashMapUnmanaged(usize, *OpenBlock) = .empty,
    pending_finish: ?types.FinishReason = null,
    finished: bool = false,
    chunks: std.ArrayList(types.Chunk) = .empty,
    response_id: ?[]const u8 = null,

    pub fn init(arena: std.mem.Allocator, pkg: []const u8, reasoning_fields: []const []const u8) Translator {
        return .{ .arena = arena, .pkg = pkg, .reasoning_fields = reasoning_fields };
    }

    pub fn deinit(self: *Translator) void {
        // arena 统管：不逐块 deinit（0.17 deinit 会把缓冲置 undefined，
        // 而 block_end chunk 仍引用这些切片——请求 arena 释放全部）。
        self.open.deinit(self.arena);
        self.tool_buckets.deinit(self.arena);
        self.chunks.deinit(self.arena);
    }

    /// 翻译一帧 SSE data 载荷；返回的 chunks 在下一次调用前有效（arena 生命周期）。
    pub fn translate(self: *Translator, data: []const u8) ![]const types.Chunk {
        self.chunks.clearRetainingCapacity();
        if (std.mem.eql(u8, data, "[DONE]")) {
            try self.appendFinalize();
            return self.chunks.items;
        }
        const parsed = std.json.parseFromSliceLeaky(std.json.Value, self.arena, data, .{}) catch {
            try self.chunks.append(self.arena, try failureChunk(self.arena, self.pkg, "malformed SSE JSON frame", "MALFORMED_RESPONSE"));
            return self.chunks.items;
        };
        if (parsed != .object) return self.chunks.items;
        const root = parsed.object;
        if (root.get("id")) |id| {
            if (id == .string) self.response_id = id.string;
        }
        if (root.get("usage")) |usage_value| {
            if (usage_value == .object) {
                if (mapUsage(usage_value.object)) |usage| {
                    try self.chunks.append(self.arena, .{ .usage = usage });
                }
            }
        }
        const choices = root.get("choices") orelse return self.chunks.items;
        if (choices != .array or choices.array.items.len == 0) return self.chunks.items;
        const choice = choices.array.items[0];
        if (choice != .object) return self.chunks.items;
        const choice_object = choice.object;

        if (choice_object.get("delta")) |delta_value| {
            if (delta_value == .object) {
                const delta = delta_value.object;
                if (reasoningText(delta, self.reasoning_fields)) |reasoning| {
                    const block = try self.ensureOpen(.reasoning);
                    try block.text.appendSlice(self.arena, reasoning);
                    try self.chunks.append(self.arena, .{ .reasoning_delta = .{ .index = block.index, .text = reasoning } });
                }
                if (delta.get("content")) |content| {
                    if (content == .string and content.string.len > 0) {
                        const block = try self.ensureOpen(.text);
                        try block.text.appendSlice(self.arena, content.string);
                        try self.chunks.append(self.arena, .{ .text_delta = .{ .index = block.index, .text = content.string } });
                    }
                }
                if (delta.get("tool_calls")) |tool_calls| {
                    if (tool_calls == .array) {
                        for (tool_calls.array.items) |fragment| {
                            if (fragment == .object) try self.toolFragment(fragment.object);
                        }
                    }
                }
            }
        }
        if (choice_object.get("finish_reason")) |finish_value| {
            if (finish_value == .string and finish_value.string.len > 0) {
                self.pending_finish = mapFinish(finish_value.string);
                try self.closeAll();
            }
        }
        return self.chunks.items;
    }

    /// 流循环结束后收尾（上游未发 [DONE] 时补 finish）。
    pub fn finalize(self: *Translator) ![]const types.Chunk {
        self.chunks.clearRetainingCapacity();
        try self.appendFinalize();
        return self.chunks.items;
    }

    fn appendFinalize(self: *Translator) !void {
        if (self.finished) return;
        if (self.pending_finish == null) {
            try self.chunks.append(self.arena, try failureChunk(self.arena, self.pkg, "stream ended before a finish reason", "MALFORMED_RESPONSE"));
            self.finished = true;
            return;
        }
        try self.chunks.append(self.arena, .{ .finish = self.pending_finish.? });
        self.finished = true;
    }

    fn reasoningText(delta: std.json.ObjectMap, fields: []const []const u8) ?[]const u8 {
        for (fields) |field| {
            const value = delta.get(field) orelse continue;
            if (value == .string and value.string.len > 0) return value.string;
        }
        return null;
    }

    fn ensureOpen(self: *Translator, kind: types.BlockKind) !*OpenBlock {
        if (self.open.items.len > 0) {
            const last = self.open.items[self.open.items.len - 1];
            if (last.kind == kind and kind != .tool_call) return last;
        }
        const block = try self.arena.create(OpenBlock);
        block.* = .{
            .kind = kind,
            .index = self.next_index,
            .text = .empty,
            .tool_id = "",
            .tool_name = .empty,
        };
        self.next_index += 1;
        try self.open.append(self.arena, block);
        return block;
    }

    fn toolFragment(self: *Translator, fragment: std.json.ObjectMap) !void {
        const vendor_index: usize = if (fragment.get("index")) |value| switch (value) {
            .integer => |number| if (number >= 0) @intCast(number) else 0,
            else => 0,
        } else 0;
        const existing = self.tool_buckets.get(vendor_index);
        const block = existing orelse blk: {
            const created = try self.arena.create(OpenBlock);
            created.* = .{
                .kind = .tool_call,
                .index = self.next_index,
                .text = .empty,
                .tool_id = try std.fmt.allocPrint(self.arena, "compat-tool-{d}", .{vendor_index}),
                .tool_name = .empty,
            };
            self.next_index += 1;
            try self.tool_buckets.put(self.arena, vendor_index, created);
            try self.open.append(self.arena, created);
            break :blk created;
        };
        var name_delta: ?[]const u8 = null;
        var args_delta: []const u8 = "";
        if (fragment.get("id")) |id| {
            if (id == .string and id.string.len > 0) block.tool_id = id.string;
        }
        if (fragment.get("function")) |function| {
            if (function == .object) {
                if (function.object.get("name")) |name| {
                    if (name == .string and name.string.len > 0) {
                        try block.tool_name.appendSlice(self.arena, name.string);
                        name_delta = name.string;
                    }
                }
                if (function.object.get("arguments")) |arguments| {
                    if (arguments == .string and arguments.string.len > 0) {
                        try block.text.appendSlice(self.arena, arguments.string);
                        args_delta = arguments.string;
                    }
                }
            }
        }
        try self.chunks.append(self.arena, .{ .tool_delta = .{
            .index = block.index,
            .id = block.tool_id,
            .name = name_delta,
            .args_delta = args_delta,
        } });
    }

    fn closeAll(self: *Translator) !void {
        for (self.open.items) |block| {
            switch (block.kind) {
                .text => try self.chunks.append(self.arena, .{ .block_end = .{ .index = block.index, .block = .{ .text = block.text.items } } }),
                .reasoning => try self.chunks.append(self.arena, .{ .block_end = .{ .index = block.index, .block = .{ .reasoning = block.text.items } } }),
                .tool_call => try self.chunks.append(self.arena, .{ .block_end = .{ .index = block.index, .block = .{ .tool_call = .{ .id = block.tool_id, .name = block.tool_name.items, .arguments = block.text.items } } } }),
            }
        }
        self.open.clearRetainingCapacity();
        self.tool_buckets.clearRetainingCapacity();
    }
};

pub fn failureChunk(arena: std.mem.Allocator, pkg: []const u8, message: []const u8, code: []const u8) !types.Chunk {
    return .{ .finish = .{ .failure = .{ .code = code, .message = try std.fmt.allocPrint(arena, "{s}: {s}", .{ pkg, message }) } } };
}

pub fn mapFinish(raw: []const u8) types.FinishReason {
    if (std.mem.eql(u8, raw, "tool_calls") or std.mem.eql(u8, raw, "function_call")) return .tool_calls;
    if (std.mem.eql(u8, raw, "length")) return .max_tokens;
    return .stop;
}

pub fn mapUsage(object: std.json.ObjectMap) ?types.Usage {
    const prompt = jsonInt(object, "prompt_tokens") orelse return null;
    const completion = jsonInt(object, "completion_tokens") orelse 0;
    var usage: types.Usage = .{ .input = prompt, .output = completion };
    if (jsonInt(object, "total_tokens")) |total| usage.total = total;
    if (object.get("prompt_tokens_details")) |details| {
        if (details == .object) {
            if (jsonInt(details.object, "cached_tokens")) |cached| {
                usage.cache_read = cached;
                usage.input -= @min(usage.input, cached);
            }
            if (jsonInt(details.object, "created_cache_tokens")) |created| usage.cache_write = created;
        }
    }
    if (object.get("completion_tokens_details")) |details| {
        if (details == .object) {
            if (jsonInt(details.object, "reasoning_tokens")) |reasoning| usage.reasoning = reasoning;
        }
    }
    return usage;
}

pub fn jsonInt(object: std.json.ObjectMap, key: []const u8) ?u64 {
    const value = object.get(key) orelse return null;
    return switch (value) {
        .integer => |number| if (number >= 0) @intCast(number) else null,
        .float => |number| if (number >= 0) @intFromFloat(number) else null,
        else => null,
    };
}

/// 上游错误响应 → Failure（TS: errors.ts）。
pub fn mapFailure(status: u16, body: []const u8, retry_after_ms: ?u64) Failure {
    var message: []const u8 = "";
    // param/code 只参与分类（OpenAI 风格把档位线索放在 "param":"reasoning_effort" 里）。
    var signals: []const u8 = "";
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, std.heap.page_allocator, body, .{}) catch null;
    if (parsed) |value| {
        if (value == .object) {
            const root = value.object;
            if (root.get("error")) |error_value| {
                if (error_value == .object) {
                    if (error_value.object.get("message")) |text| {
                        if (text == .string) message = text.string;
                    }
                    const param = jsonGetString(error_value.object, "param") orelse "";
                    const code = jsonGetString(error_value.object, "code") orelse "";
                    if (param.len > 0 or code.len > 0) {
                        signals = std.fmt.allocPrint(std.heap.page_allocator, "{s} {s}", .{ param, code }) catch "";
                    }
                }
            }
            if (message.len == 0) {
                if (root.get("detail")) |detail| {
                    if (detail == .string) message = detail.string;
                }
            }
        }
    }
    const classify_input = if (signals.len > 0)
        std.fmt.allocPrint(std.heap.page_allocator, "{s} {s}", .{ message, signals }) catch message
    else
        message;
    return .{ .status = status, .code = classify(status, classify_input), .message = message, .retry_after_ms = retry_after_ms };
}

/// 网关行为分类：AUTH/RATE_LIMIT/CONTEXT_WINDOW_EXCEEDED/PATH_MISMATCH/
/// EFFORT_UNSUPPORTED/SERVER/INVALID_REQUEST。
/// 前五类里 PATH_MISMATCH 与 EFFORT_UNSUPPORTED 是运行时自愈的触发器。
fn classify(status: u16, message: []const u8) []const u8 {
    if (status == 401 or status == 403) return "AUTH";
    if (status == 429) return "RATE_LIMIT";
    if (isContextWindowExceeded(message)) return "CONTEXT_WINDOW_EXCEEDED";
    if (looksLikePathMismatch(status, message)) return "PATH_MISMATCH";
    if (looksLikeEffortUnsupported(status, message)) return "EFFORT_UNSUPPORTED";
    if (status >= 500) return "SERVER";
    return "INVALID_REQUEST";
}

/// 路径/方言不匹配：404/405；或 400/422 且文案带"端点不存在"类信号。
/// 模型不存在的 404 要排除（那是路由正确、模型名错）。
fn looksLikePathMismatch(status: u16, message: []const u8) bool {
    var buffer: [1024]u8 = undefined;
    const lower = lowerInto(&buffer, message);
    if (containsAny(lower, &.{
        "no such model", "model not found", "unknown model", "model_not_found",
        "模型不存在",
        "模型未找到",
        "不存在的模型",
    })) return false;
    if (status == 404 or status == 405) return true;
    if (status == 400 or status == 422) {
        return containsAny(lower, &.{
            "not found",               "unknown endpoint", "no such route", "invalid url",
            "未知端点",
            "路由不存在",
            "接口不存在",
            "endpoint does not exist",
        });
    }
    return false;
}

/// 档位（思考强度）被上游拒绝：400/422 且文案/参数名带思考类信号（中英双语）。
fn looksLikeEffortUnsupported(status: u16, message: []const u8) bool {
    if (status != 400 and status != 422) return false;
    var buffer: [1024]u8 = undefined;
    const lower = lowerInto(&buffer, message);
    return containsAny(lower, &.{
        "reasoning_effort",     "reasoning effort",  "reasoning.effort",
        "reasoning",            "thinking",          "effort",
        "思考",
        "不支持关闭",
        "supported values are", "unsupported value",
    });
}

fn containsAny(haystack: []const u8, needles: []const []const u8) bool {
    for (needles) |needle| {
        if (std.mem.indexOf(u8, haystack, needle) != null) return true;
    }
    return false;
}

fn jsonGetString(object: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = object.get(key) orelse return null;
    return switch (value) {
        .string => |text| text,
        else => null,
    };
}

fn isContextWindowExceeded(message: []const u8) bool {
    var buffer: [1024]u8 = undefined;
    const lower = lowerInto(&buffer, message);
    const patterns = [_][]const u8{ "context length", "context window", "maximum context", "too large for", "too long for" };
    for (patterns) |pattern| {
        if (std.mem.indexOf(u8, lower, pattern) != null) return true;
    }
    return false;
}

fn lowerInto(buffer: []u8, text: []const u8) []const u8 {
    const n = @min(buffer.len, text.len);
    for (text[0..n], 0..) |byte, index| buffer[index] = std.ascii.toLower(byte);
    return buffer[0..n];
}

// ---------------------------------------------------------------------------
// 上游调用：HTTPS POST + SSE 循环 → Chunk 回调
// ---------------------------------------------------------------------------

/// 发起一次上游流式调用；每个翻译后的 Chunk 调用一次 onChunk。
/// 供应商错误（非 2xx）→ failure_out 记录 + error.UpstreamFailure。
pub fn callStreaming(
    arena: std.mem.Allocator,
    io: std.Io,
    profile: *const providers_mod.Profile,
    request: types.GenerateRequest,
    failure_out: *?Failure,
    ctx: anytype,
    comptime onChunk: fn (@TypeOf(ctx), types.Chunk) anyerror!void,
) !void {
    // key 中转：环境变量优先；缺失时用入站请求携带的 key；都没有 → 快速失败且**不重试**（配置问题）。
    const resolved_key = client_key.resolve(profile.api_key_env);
    const key = resolved_key.key;
    if (key.len == 0) {
        failure_out.* = .{
            .status = 401,
            .code = "MISSING_CREDENTIAL",
            .message = try std.fmt.allocPrint(arena, "no API key: export {s}, or send the key with the request (x-api-key / Authorization: Bearer)", .{profile.api_key_env}),
        };
        return error.MissingCredential;
    }
    if (resolved_key.from_client) {
        std.debug.print("[llm-shim] {s}: forwarding the inbound client API key upstream ({s} unset)\n", .{ profile.name, profile.api_key_env });
    }
    const body = try serializeBody(arena, profile, request);
    const url = try std.fmt.allocPrint(arena, "{s}/chat/completions", .{std.mem.trimEnd(u8, profile.base_url, "/")});
    const uri = std.Uri.parse(url) catch return error.InvalidUpstreamUrl;

    var client: Client = .init(std.heap.page_allocator, io);
    defer client.deinit();

    const bearer = try std.fmt.allocPrint(arena, "Bearer {s}", .{key});
    // 看门狗接线：本次尝试重新武装空闲超时（自愈重试会再次进入这里）
    watchdog_mod.beginAttempt();
    var req = try client.http.request(.POST, uri, .{
        .headers = .{
            .authorization = .{ .override = bearer },
            .content_type = .{ .override = "application/json" },
        },
        .extra_headers = &.{
            .{ .name = "user-agent", .value = version_mod.userAgent() },
            .{ .name = "accept", .value = "text/event-stream" },
        },
    });
    defer req.deinit();
    // 回填上游连接句柄：空闲超时时看门狗用它 shutdown 打断阻塞读
    if (req.connection) |connection| watchdog_mod.noteUpstreamSocket(connection.stream_reader.stream.socket.handle);
    try req.sendBodyComplete(@constCast(body));
    var redirect_buffer: [8192]u8 = undefined;
    var response = try req.receiveHead(&redirect_buffer);

    const status_code = @backingInt(response.head.status);
    if (status_code < 200 or status_code > 299) {
        // reader() 会 invalidateStrings()，头部必须在取 body reader 之前读。
        const retry_after = retryAfterMs(response.head);
        var transfer_buffer: [16384]u8 = undefined;
        const body_reader = response.reader(&transfer_buffer);
        const error_body = body_reader.allocRemaining(arena, .limited(1 << 20)) catch "";
        failure_out.* = mapFailure(status_code, error_body, retry_after);
        return error.UpstreamFailure;
    }

    var transfer_buffer: [16384]u8 = undefined;
    const body_reader = response.reader(&transfer_buffer);
    var translator = Translator.init(arena, "llm-shim", profile.reasoning_delta_fields);
    defer translator.deinit();

    while (true) {
        const frame = (try http_util.SseParser.next(body_reader, arena)) orelse break;
        if (frame.data.len == 0) continue;
        const chunks = try translator.translate(frame.data);
        for (chunks) |chunk| try onChunk(ctx, chunk);
        if (translator.finished) break;
    }
    // 看门狗空闲超时打断：EOF 发生在收尾之前 → 归类为 TIMEOUT（交给自愈退避重试），
    // 而不是让翻译器把"截断的流"报成 MALFORMED（那会被判为不可重试）。
    if (!translator.finished and watchdog_mod.upstreamTimedOut()) {
        failure_out.* = .{ .status = 504, .code = "TIMEOUT", .message = "upstream idle timeout (watchdog interrupted the blocked read)" };
        return error.UpstreamFailure;
    }
    const tail = try translator.finalize();
    for (tail) |chunk| try onChunk(ctx, chunk);
}

test "classify: 既有五类 + 自愈触发器" {
    try std.testing.expectEqualStrings("AUTH", classify(401, ""));
    try std.testing.expectEqualStrings("AUTH", classify(403, "forbidden"));
    try std.testing.expectEqualStrings("RATE_LIMIT", classify(429, "slow down"));
    try std.testing.expectEqualStrings("CONTEXT_WINDOW_EXCEEDED", classify(400, "This model's maximum context length is 8192 tokens"));
    try std.testing.expectEqualStrings("SERVER", classify(503, "unavailable"));
    try std.testing.expectEqualStrings("INVALID_REQUEST", classify(400, "temperature must be <= 2"));

    try std.testing.expectEqualStrings("PATH_MISMATCH", classify(404, "404 page not found"));
    try std.testing.expectEqualStrings("PATH_MISMATCH", classify(405, "Method Not Allowed"));
    try std.testing.expectEqualStrings("PATH_MISMATCH", classify(400, "unknown endpoint: /v1/foo"));
    // 模型不存在的 404 = 路由正确、模型名错，不能当路径问题
    try std.testing.expectEqualStrings("INVALID_REQUEST", classify(404, "model not found: foo"));

    try std.testing.expectEqualStrings("EFFORT_UNSUPPORTED", classify(400, "该模型始终思考，不支持关闭思考；请使用 low、high 或 medium"));
    try std.testing.expectEqualStrings("EFFORT_UNSUPPORTED", classify(422, "reasoning_effort: invalid value"));
    try std.testing.expectEqualStrings("EFFORT_UNSUPPORTED", classify(400, "Unsupported value: 'minimal' is not supported with this model."));
}

const test_models = [_]providers_mod.Model{
    .{ .id = "text-model", .name = "T", .context_window = 1000, .vision = false },
    .{ .id = "vision-model", .name = "V", .context_window = 1000, .vision = true },
};

fn testProfile() providers_mod.Profile {
    return .{
        .name = "p",
        .display_name = "P",
        .base_url = "http://x",
        .api_key_env = "K",
        .protocol = .openai,
        .models = &test_models,
        .effort_strategy = .passthrough_off_none,
    };
}

fn expectContains(haystack: []const u8, needle: []const u8) !void {
    try std.testing.expect(std.mem.indexOf(u8, haystack, needle) != null);
}

test "upstream.openai serializeBody: 档位两种 wire / stop 门控 / 基础字段" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const base = testProfile();
    var request = types.GenerateRequest{
        .provider = "p",
        .model = "text-model",
        .messages = &.{},
        .reasoning_effort = .off,
        .max_tokens = 64,
        .temperature = 0.5,
        .stop = &.{"END"},
    };

    const body = try serializeBody(arena, &base, request);
    try expectContains(body, "\"reasoning_effort\":\"none\""); // intern 剖面 off→none
    try expectContains(body, "\"stop\":[\"END\"]");
    try expectContains(body, "\"stream\":true");
    try expectContains(body, "\"stream_options\":{\"include_usage\":true}");
    try expectContains(body, "\"max_tokens\":64");
    try expectContains(body, "\"temperature\":0.5");

    // effort_wire=.reasoning（openrouter 形态）+ passthrough
    var reasoning_wire = base;
    reasoning_wire.effort_wire = .reasoning;
    reasoning_wire.effort_strategy = .passthrough;
    request.reasoning_effort = .high;
    const body2 = try serializeBody(arena, &reasoning_wire, request);
    try expectContains(body2, "\"reasoning\":{\"effort\":\"high\"}");

    // honors_stop=false（AMD 白名单静默丢弃）→ 不发 stop
    var no_stop = base;
    no_stop.honors_stop = false;
    const body3 = try serializeBody(arena, &no_stop, request);
    try std.testing.expect(std.mem.indexOf(u8, body3, "\"stop\"") == null);

    // omit_always（未知厂商防 400）→ 不发档位字段
    var omit = base;
    omit.effort_strategy = .omit_always;
    const body4 = try serializeBody(arena, &omit, request);
    try std.testing.expect(std.mem.indexOf(u8, body4, "reasoning") == null);
}

test "upstream.openai serializeMessages: 视觉占位/空消息/函数调用" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const profile = testProfile();

    const messages = [_]types.Message{
        .{ .role = .user, .blocks = &.{ .{ .text = "看图" }, .{ .image = .{ .data_uri = "data:image/png;base64,AQID" } } } },
        .{ .role = .user, .blocks = &.{.{ .text = "" }} }, // 空消息 → 跳过
        .{ .role = .assistant, .blocks = &.{.{ .tool_call = .{ .id = "c1", .name = "fn", .arguments = "{}" } }} },
    };
    var request = types.GenerateRequest{ .provider = "p", .model = "vision-model", .messages = &messages, .system = "SYS" };

    const vision = try serializeMessages(arena, &profile, "vision-model", request);
    try expectContains(vision, "\"role\":\"system\",\"content\":\"SYS\"");
    try expectContains(vision, "image_url");
    try expectContains(vision, "\"tool_calls\":[{\"id\":\"c1\"");
    try expectContains(vision, "\"content\":null"); // 仅工具、无文本 → content null
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, vision, "\"role\":\"user\"")); // 空 user 被跳过

    // 非视觉模型 → 图片替换为占位文本
    request.model = "text-model";
    const plain = try serializeMessages(arena, &profile, "text-model", request);
    try std.testing.expect(std.mem.indexOf(u8, plain, "image_url") == null);
    try expectContains(plain, "[图片已省略");
}

test "upstream.openai Translator: 推理字段优先级/工具累积/finish 收尾" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var translator = Translator.init(arena, "pkg", &.{ "reasoning", "reasoning_content" });
    defer translator.deinit();

    // 推理字段优先级：第一顺位非空者胜出
    const r = try translator.translate("{\"choices\":[{\"delta\":{\"reasoning_content\":\"B\",\"reasoning\":\"A\"}}]}");
    try std.testing.expectEqualStrings("A", r[0].reasoning_delta.text);
    // 文本
    const t = try translator.translate("{\"choices\":[{\"delta\":{\"content\":\"答\"}}]}");
    try std.testing.expectEqualStrings("答", t[0].text_delta.text);
    // 工具两帧：首帧带 id/name 与参数片段，次帧仅参数
    const g1 = try translator.translate("{\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"call_1\",\"function\":{\"name\":\"fn\",\"arguments\":\"{\\\"a\\\":\"}}]}}]}");
    try std.testing.expectEqualStrings("call_1", g1[0].tool_delta.id);
    try std.testing.expectEqualStrings("fn", g1[0].tool_delta.name.?);
    const g2 = try translator.translate("{\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"arguments\":\"1}\"}}]}}]}");
    try std.testing.expect(g2[0].tool_delta.name == null);
    try std.testing.expectEqualStrings("1}", g2[0].tool_delta.args_delta);

    // finish_reason → closeAll：三个 block_end（推理/文本/工具），工具带完整三元组
    const closed = try translator.translate("{\"choices\":[{\"delta\":{},\"finish_reason\":\"tool_calls\"}]}");
    try std.testing.expectEqual(@as(usize, 3), closed.len);
    var tool_end: ?types.ToolCall = null;
    for (closed) |chunk| {
        switch (chunk) {
            .block_end => |end| switch (end.block) {
                .tool_call => |call| tool_end = call,
                else => {},
            },
            else => {},
        }
    }
    try std.testing.expectEqualStrings("call_1", tool_end.?.id);
    try std.testing.expectEqualStrings("fn", tool_end.?.name);
    try std.testing.expectEqualStrings("{\"a\":1}", tool_end.?.arguments);

    // [DONE] → finish（tool_calls）
    const done = try translator.translate("[DONE]");
    try std.testing.expectEqual(@as(usize, 1), done.len);
    try std.testing.expect(done[0] == .finish);
    try std.testing.expect(done[0].finish == .tool_calls);
    // finalize 幂等
    try std.testing.expectEqual(@as(usize, 0), (try translator.finalize()).len);
}

test "upstream.openai Translator: usage 映射与畸形帧/缺 finish" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var translator = Translator.init(arena, "pkg", &.{"reasoning_content"});
    defer translator.deinit();
    const usage_frames = try translator.translate("{\"choices\":[],\"usage\":{\"prompt_tokens\":10,\"completion_tokens\":5,\"total_tokens\":15,\"prompt_tokens_details\":{\"cached_tokens\":3},\"completion_tokens_details\":{\"reasoning_tokens\":2}}}");
    try std.testing.expectEqual(@as(usize, 1), usage_frames.len);
    const usage = usage_frames[0].usage;
    try std.testing.expectEqual(@as(u64, 7), usage.input); // prompt − cached
    try std.testing.expectEqual(@as(u64, 3), usage.cache_read);
    try std.testing.expectEqual(@as(u64, 2), usage.reasoning);
    try std.testing.expectEqual(@as(u64, 15), usage.total.?);

    // 畸形 JSON 帧 → MALFORMED_RESPONSE failure
    const malformed = try translator.translate("not json");
    switch (malformed[0]) {
        .finish => |reason| {
            try std.testing.expect(reason == .failure);
            try std.testing.expectEqualStrings("MALFORMED_RESPONSE", reason.failure.code);
        },
        else => return error.UnexpectedChunk,
    }

    // 有 finish_reason 但未收尾 → finalize 补 finish
    var t2 = Translator.init(arena, "pkg", &.{"reasoning_content"});
    defer t2.deinit();
    _ = try t2.translate("{\"choices\":[{\"delta\":{\"content\":\"x\"},\"finish_reason\":\"stop\"}]}");
    const tail = try t2.finalize();
    try std.testing.expectEqual(@as(usize, 1), tail.len);
    try std.testing.expect(tail[0] == .finish);
    try std.testing.expect(tail[0].finish == .stop);

    // 全程无 finish_reason → MALFORMED
    var t3 = Translator.init(arena, "pkg", &.{"reasoning_content"});
    defer t3.deinit();
    _ = try t3.translate("{\"choices\":[{\"delta\":{\"content\":\"x\"}}]}");
    const tail3 = try t3.finalize();
    switch (tail3[0]) {
        .finish => |reason| try std.testing.expect(reason == .failure),
        else => return error.UnexpectedChunk,
    }
}

test "mapFailure: param/code 参与分类，message 保持原文" {
    const body = "{\"error\":{\"message\":\"Unsupported value: 'minimal' is not supported with this model.\",\"param\":\"reasoning_effort\",\"code\":\"unsupported_value\"}}";
    const failure = mapFailure(400, body, null);
    try std.testing.expectEqualStrings("EFFORT_UNSUPPORTED", failure.code);
    try std.testing.expectEqualStrings("Unsupported value: 'minimal' is not supported with this model.", failure.message);

    // param 单独携带档位线索（message 里没有关键词）
    const param_only = mapFailure(400, "{\"error\":{\"message\":\"invalid request\",\"param\":\"reasoning_effort\"}}", null);
    try std.testing.expectEqualStrings("EFFORT_UNSUPPORTED", param_only.code);

    // FastAPI detail 信封
    const detail_failure = mapFailure(422, "{\"detail\":\"[{'loc': ('body','reasoning_effort')}]\"}", null);
    try std.testing.expectEqualStrings("EFFORT_UNSUPPORTED", detail_failure.code);

    // Retry-After 透传
    const limited = mapFailure(429, "{\"error\":{\"message\":\"rate limited\"}}", 3000);
    try std.testing.expectEqualStrings("RATE_LIMIT", limited.code);
    try std.testing.expectEqual(@as(?u64, 3000), limited.retry_after_ms);
}

test "resolveProvider/ambiguousCandidates: 歧义按供应商计，候选按注册顺序" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var registry = try providers_mod.builtinRegistry(arena);
    defer registry.deinit();
    // 与内置 intern-ai 撞模型的自定义条目（同端点去重后不应再出现，
    // 但手工/遗留文件仍可能产生）→ 歧义：候选列出两家。
    try registry.profiles.append(arena, .{
        .name = "custom-1",
        .display_name = "custom-1",
        .base_url = "https://custom.example/v1",
        .api_key_env = "CUSTOM_KEY",
        .protocol = .openai,
        .models = &.{.{ .id = "glm-5.3", .name = "GLM-5.3", .context_window = 0, .vision = false }},
        .aliases = &.{.{ .from = "glm-5.3-flash", .to = "GLM-5.3-Flash" }},
    });

    try std.testing.expectError(error.AmbiguousModel, resolveProvider(&registry, "glm-5.3"));
    const candidates = try ambiguousCandidates(arena, &registry, "glm-5.3");
    try std.testing.expectEqual(@as(usize, 2), candidates.len);
    try std.testing.expectEqualStrings("intern-ai", candidates[0]);
    try std.testing.expectEqualStrings("custom-1", candidates[1]);

    // 别名撞车同样歧义（glm-5.3-flash 在 amd-radeon 与 custom-1 都有）
    try std.testing.expectError(error.AmbiguousModel, resolveProvider(&registry, "glm-5.3-flash"));
    const alias_candidates = try ambiguousCandidates(arena, &registry, "glm-5.3-flash");
    try std.testing.expectEqual(@as(usize, 2), alias_candidates.len);
    try std.testing.expectEqualStrings("amd-radeon", alias_candidates[0]);
    try std.testing.expectEqualStrings("custom-1", alias_candidates[1]);

    // provider/model 前缀仍可解析（歧义的出路）
    const resolved = try resolveProvider(&registry, "custom-1/glm-5.3");
    try std.testing.expectEqualStrings("custom-1", resolved.profile.name);
    // 别名走前缀 → 线上原始大小写
    const alias_resolved = try resolveProvider(&registry, "custom-1/glm-5.3-flash");
    try std.testing.expectEqualStrings("GLM-5.3-Flash", alias_resolved.model);

    // 未命中/非歧义 → 候选为空
    try std.testing.expectEqual(@as(usize, 0), (try ambiguousCandidates(arena, &registry, "nope")).len);
    try std.testing.expectEqual(@as(usize, 0), (try ambiguousCandidates(arena, &registry, "intern-ai/glm-5.3")).len);
}

test "resolveProvider: 同一剖面内重复 id 不算歧义（TS filter 语义）" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var registry = providers_mod.Registry{ .allocator = arena, .profiles = .empty };
    defer registry.deinit();
    try registry.profiles.append(arena, .{
        .name = "dupe",
        .display_name = "dupe",
        .base_url = "https://dupe.example/v1",
        .api_key_env = "DUPE_KEY",
        .protocol = .openai,
        .models = &.{
            .{ .id = "m1", .name = "m1", .context_window = 0, .vision = false },
            .{ .id = "m1", .name = "m1", .context_window = 0, .vision = false },
        },
    });
    const resolved = try resolveProvider(&registry, "m1");
    try std.testing.expectEqualStrings("dupe", resolved.profile.name);
    try std.testing.expectEqual(@as(usize, 0), (try ambiguousCandidates(arena, &registry, "m1")).len);
}
