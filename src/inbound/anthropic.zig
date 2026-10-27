//! Anthropic Messages 入站：解析 → GenerateRequest；Chunk → message 响应/SSE 事件。
const std = @import("std");
const types = @import("../types.zig");
const effort_mod = @import("../effort.zig");
const providers_mod = @import("../providers.zig");
const placeholder_mod = @import("../placeholder.zig");
const clock = @import("../clock.zig");

pub const Parsed = struct {
    request: types.GenerateRequest,
    stream: bool,
    model_echo: []const u8,
};

/// thinking 预算 → 档位（TS: thinkingBudgetToEffort）。
fn thinkingToEffort(body: std.json.ObjectMap) ?types.Effort {
    const thinking = body.get("thinking") orelse return null;
    if (thinking != .object) return null;
    const kind = thinking.object.get("type") orelse return null;
    if (kind != .string) return null;
    if (std.mem.eql(u8, kind.string, "disabled")) return .off;
    if (!std.mem.eql(u8, kind.string, "enabled")) return null;
    const budget = thinking.object.get("budget_tokens") orelse return .medium;
    if (budget != .integer) return .medium;
    return effort_mod.thinkingBudgetToEffort(@floatFromInt(budget.integer));
}

pub fn parse(
    arena: std.mem.Allocator,
    registry: *providers_mod.Registry,
    body: std.json.ObjectMap,
) !Parsed {
    const model_value = body.get("model") orelse return error.MissingModel;
    if (model_value != .string or model_value.string.len == 0) return error.MissingModel;
    const model_echo = model_value.string;

    const openai_mod = @import("../upstream/openai.zig");
    const resolved = try openai_mod.resolveProvider(registry, model_echo);

    var messages: std.ArrayList(types.Message) = .empty;

    // system → 顶层 system 字符串 / 数组拼接
    var system_text: ?[]const u8 = null;
    if (body.get("system")) |system| {
        switch (system) {
            .string => |text| {
                if (text.len > 0) system_text = text;
            },
            .array => |parts| {
                var buffer: std.ArrayList(u8) = .empty;
                for (parts.items) |part| {
                    if (part != .object) continue;
                    if (part.object.get("type")) |kind| {
                        if (kind == .string and std.mem.eql(u8, kind.string, "text")) {
                            if (part.object.get("text")) |text| {
                                if (text == .string) {
                                    if (buffer.items.len > 0) try buffer.append(arena, '\n');
                                    try buffer.appendSlice(arena, text.string);
                                }
                            }
                        }
                    }
                }
                if (buffer.items.len > 0) system_text = buffer.items;
            },
            else => {},
        }
    }

    const raw_messages = body.get("messages") orelse return error.MissingMessages;
    if (raw_messages != .array or raw_messages.array.items.len == 0) return error.MissingMessages;

    for (raw_messages.array.items) |raw| {
        if (raw != .object) continue;
        const message = raw.object;
        const role = message.get("role") orelse continue;
        if (role != .string) continue;
        const content = message.get("content");

        if (std.mem.eql(u8, role.string, "user")) {
            var blocks: std.ArrayList(types.Block) = .empty;
            switch (content orelse std.json.Value{ .null = {} }) {
                .string => |text| {
                    if (text.len > 0) try blocks.append(arena, .{ .text = text });
                },
                .array => |parts| {
                    for (parts.items) |part| {
                        if (part != .object) continue;
                        const kind = part.object.get("type") orelse continue;
                        if (kind != .string) continue;
                        if (std.mem.eql(u8, kind.string, "text")) {
                            if (part.object.get("text")) |text| {
                                if (text == .string and text.string.len > 0) {
                                    try blocks.append(arena, .{ .text = text.string });
                                }
                            }
                        } else if (std.mem.eql(u8, kind.string, "image")) {
                            if (part.object.get("source")) |source| {
                                if (source == .object) {
                                    const source_type = source.object.get("type");
                                    if (source_type != null and source_type.? == .string) {
                                        if (std.mem.eql(u8, source_type.?.string, "base64")) {
                                            const media = source.object.get("media_type") orelse continue;
                                            const data = source.object.get("data") orelse continue;
                                            if (media != .string or data != .string) continue;
                                            const uri = try std.fmt.allocPrint(arena, "data:{s};base64,{s}", .{ media.string, data.string });
                                            try blocks.append(arena, .{ .image = .{ .data_uri = uri } });
                                        } else if (std.mem.eql(u8, source_type.?.string, "url")) {
                                            const url = source.object.get("url") orelse continue;
                                            if (url != .string or url.string.len == 0) continue;
                                            try blocks.append(arena, .{ .image = .{ .data_uri = url.string } });
                                        }
                                    }
                                }
                            }
                        } else if (std.mem.eql(u8, kind.string, "tool_result")) {
                            const call_id = part.object.get("tool_use_id") orelse continue;
                            if (call_id != .string) continue;
                            var text: []const u8 = "";
                            if (part.object.get("content")) |result| {
                                text = switch (result) {
                                    .string => |value| value,
                                    .array => |items| blk: {
                                        var buffer: std.ArrayList(u8) = .empty;
                                        for (items.items) |item| {
                                            if (item != .object) continue;
                                            if (item.object.get("text")) |t| {
                                                if (t == .string) {
                                                    if (buffer.items.len > 0) try buffer.append(arena, '\n');
                                                    try buffer.appendSlice(arena, t.string);
                                                }
                                            }
                                        }
                                        break :blk buffer.items;
                                    },
                                    else => "",
                                };
                            }
                            const tool_blocks = try arena.alloc(types.Block, 2);
                            tool_blocks[0] = .{ .tool_call = .{ .id = call_id.string, .name = "", .arguments = "{}" } };
                            tool_blocks[1] = .{ .text = text };
                            try messages.append(arena, .{ .role = .tool, .blocks = tool_blocks });
                        }
                    }
                },
                else => {},
            }
            const meaningful = blk: {
                for (blocks.items) |block| {
                    switch (block) {
                        .image => break :blk true,
                        .text => |text| {
                            if (text.len > 0) break :blk true;
                        },
                        else => {},
                    }
                }
                break :blk false;
            };
            if (!meaningful) continue;
            try messages.append(arena, .{ .role = .user, .blocks = try blocks.toOwnedSlice(arena) });
            continue;
        }
        if (std.mem.eql(u8, role.string, "assistant")) {
            var blocks: std.ArrayList(types.Block) = .empty;
            if (content) |content_value| {
                switch (content_value) {
                    .string => |text| {
                        if (text.len > 0) try blocks.append(arena, .{ .text = text });
                    },
                    .array => |parts| {
                        for (parts.items) |part| {
                            if (part != .object) continue;
                            const kind = part.object.get("type") orelse continue;
                            if (kind != .string) continue;
                            if (std.mem.eql(u8, kind.string, "text")) {
                                if (part.object.get("text")) |text| {
                                    if (text == .string and text.string.len > 0) {
                                        try blocks.append(arena, .{ .text = text.string });
                                    }
                                }
                            } else if (std.mem.eql(u8, kind.string, "tool_use")) {
                                const call_id = part.object.get("id") orelse continue;
                                const name = part.object.get("name") orelse continue;
                                if (call_id != .string or name != .string) continue;
                                var arguments: []const u8 = "{}";
                                if (part.object.get("input")) |input| {
                                    arguments = std.json.Stringify.valueAlloc(arena, input, .{}) catch "{}";
                                }
                                try blocks.append(arena, .{ .tool_call = .{ .id = call_id.string, .name = name.string, .arguments = arguments } });
                            }
                        }
                    },
                    else => {},
                }
            }
            if (blocks.items.len == 0) continue;
            try messages.append(arena, .{ .role = .assistant, .blocks = try blocks.toOwnedSlice(arena) });
        }
    }
    if (messages.items.len == 0) return error.EmptyRequest;

    var tools: ?[]const types.ToolSchema = null;
    if (body.get("tools")) |tools_value| {
        if (tools_value == .array and tools_value.array.items.len > 0) {
            var tool_list: std.ArrayList(types.ToolSchema) = .empty;
            for (tools_value.array.items) |raw_tool| {
                if (raw_tool != .object) continue;
                const name = raw_tool.object.get("name") orelse continue;
                if (name != .string) continue;
                const description: []const u8 = if (raw_tool.object.get("description")) |value| switch (value) {
                    .string => |text| text,
                    else => "",
                } else "";
                const parameters: std.json.Value = raw_tool.object.get("input_schema") orelse try std.json.parseFromSliceLeaky(std.json.Value, arena, "{\"type\":\"object\",\"properties\":{}}", .{});
                try tool_list.append(arena, .{ .name = name.string, .description = description, .parameters = parameters });
            }
            if (tool_list.items.len > 0) tools = try tool_list.toOwnedSlice(arena);
        }
    }

    var max_tokens: ?u64 = null;
    if (body.get("max_tokens")) |value| {
        if (value == .integer and value.integer > 0) max_tokens = @intCast(value.integer);
    }

    return .{
        .request = .{
            .provider = resolved.profile.name,
            .model = resolved.model,
            .messages = try placeholder_mod.stripFromMessages(arena, try messages.toOwnedSlice(arena)),
            .system = try placeholder_mod.stripOptional(arena, system_text),
            .reasoning_effort = thinkingToEffort(body),
            .tools = tools,
            .max_tokens = max_tokens,
        },
        .stream = if (body.get("stream")) |value| value == .bool and value.bool else false,
        .model_echo = model_echo,
    };
}

// ---------------------------------------------------------------------------
// 非流式组装 + 流式发射（TS: assembleAnthropicMessage / AnthropicStreamOut）
// ---------------------------------------------------------------------------

pub fn mapStopToWire(kind: types.FinishReason) []const u8 {
    return switch (kind) {
        .tool_calls => "tool_use",
        .max_tokens => "max_tokens",
        else => "end_turn",
    };
}

pub fn assembleMessage(arena: std.mem.Allocator, model_echo: []const u8, chunks: []const types.Chunk) ![]const u8 {
    var content: std.ArrayList(u8) = .empty;
    var text: std.ArrayList(u8) = .empty;
    var reasoning: std.ArrayList(u8) = .empty;
    var tool_calls: std.ArrayList(u8) = .empty;
    var input_tokens: u64 = 0;
    var output_tokens: u64 = 0;
    var stop: []const u8 = "end_turn";

    const flush = struct {
        fn run(arena2: std.mem.Allocator, content2: *std.ArrayList(u8), reasoning2: *std.ArrayList(u8), text2: *std.ArrayList(u8), tools2: *std.ArrayList(u8)) !void {
            if (reasoning2.items.len > 0) {
                const part = try std.fmt.allocPrint(arena2, "{{\"type\":\"thinking\",\"thinking\":{f}}}", .{std.json.fmt(reasoning2.items, .{})});
                if (content2.items.len > 0) try content2.append(arena2, ',');
                try content2.appendSlice(arena2, part);
                reasoning2.clearRetainingCapacity();
            }
            if (text2.items.len > 0) {
                const part = try std.fmt.allocPrint(arena2, "{{\"type\":\"text\",\"text\":{f}}}", .{std.json.fmt(text2.items, .{})});
                if (content2.items.len > 0) try content2.append(arena2, ',');
                try content2.appendSlice(arena2, part);
                text2.clearRetainingCapacity();
            }
            if (tools2.items.len > 0) {
                if (content2.items.len > 0) try content2.append(arena2, ',');
                try content2.appendSlice(arena2, tools2.items);
                tools2.clearRetainingCapacity();
            }
        }
    }.run;

    // TS 行为：按 kind 切换才 flush（同 kind 连续 delta 累积）。
    var current_kind: ?types.BlockKind = null;
    for (chunks) |chunk| {
        switch (chunk) {
            .text_delta => |delta| {
                if (current_kind != .text) {
                    try flush(arena, &content, &reasoning, &text, &tool_calls);
                    current_kind = .text;
                }
                try text.appendSlice(arena, delta.text);
            },
            .reasoning_delta => |delta| {
                if (current_kind != .reasoning) {
                    try flush(arena, &content, &reasoning, &text, &tool_calls);
                    current_kind = .reasoning;
                }
                try reasoning.appendSlice(arena, delta.text);
            },
            .block_end => |end| {
                if (end.block == .tool_call) {
                    const call = end.block.tool_call;
                    const part = try std.fmt.allocPrint(arena, "{{\"type\":\"tool_use\",\"id\":{f},\"name\":{f},\"input\":{s}}}", .{
                        std.json.fmt(call.id, .{}), std.json.fmt(call.name, .{}), jsonOrEmptyObject(arena, call.arguments),
                    });
                    try flush(arena, &content, &reasoning, &text, &tool_calls);
                    current_kind = .tool_call;
                    try tool_calls.appendSlice(arena, part);
                }
            },
            .usage => |usage| {
                input_tokens = usage.input + usage.cache_read + usage.cache_write;
                output_tokens = usage.output;
            },
            .finish => |reason| stop = mapStopToWire(reason),
            else => {},
        }
    }
    try flush(arena, &content, &reasoning, &text, &tool_calls);

    return std.fmt.allocPrint(arena, "{{\"id\":\"gwmsg-{d}\",\"type\":\"message\",\"role\":\"assistant\",\"model\":{f},\"content\":[{s}],\"stop_reason\":{f},\"stop_sequence\":null,\"usage\":{{\"input_tokens\":{d},\"output_tokens\":{d}}}}}", .{
        clock.unixMilli(), std.json.fmt(model_echo, .{}), content.items, std.json.fmt(stop, .{}), input_tokens, output_tokens,
    });
}

fn jsonOrEmptyObject(arena: std.mem.Allocator, raw: []const u8) []const u8 {
    _ = std.json.parseFromSliceLeaky(std.json.Value, arena, raw, .{}) catch return "{}";
    return raw;
}

/// 流式发射器（TS: AnthropicStreamOut）：message_start → content_block_* →
/// message_delta → message_stop。
pub const StreamOut = struct {
    arena: std.mem.Allocator,
    model_echo: []const u8,
    next_index: usize = 0,
    open_index: ?usize = null,
    open_dsh_index: ?usize = null,
    /// 当前打开块的种类（占位注入要据此决定是否安全）。
    open_kind: ?types.BlockKind = null,
    /// 占位帧开的文本块：下一个真实文本增量直接复用（避免把回答切成两块）。
    adopt_next_text: bool = false,
    started: bool = false,
    finished: bool = false,
    input_tokens: u64 = 0,
    output_tokens: u64 = 0,
    pending_stop: ?[]const u8 = null,

    pub fn init(arena: std.mem.Allocator, model_echo: []const u8) StreamOut {
        return .{ .arena = arena, .model_echo = model_echo };
    }

    fn event(arena: std.mem.Allocator, name: []const u8, payload: []const u8) ![]const u8 {
        return std.fmt.allocPrint(arena, "event: {s}\ndata: {s}\n\n", .{ name, payload });
    }

    fn messageStart(self: *StreamOut) ![]const u8 {
        return event(self.arena, "message_start", try std.fmt.allocPrint(self.arena, "{{\"type\":\"message_start\",\"message\":{{\"id\":\"gwmsg-{d}\",\"type\":\"message\",\"role\":\"assistant\",\"model\":{f},\"content\":[],\"stop_reason\":null,\"stop_sequence\":null,\"usage\":{{\"input_tokens\":{d},\"output_tokens\":0}}}}}}", .{
            clock.unixMilli(), std.json.fmt(self.model_echo, .{}), self.input_tokens,
        }));
    }

    fn closeOpen(self: *StreamOut, frames: *std.ArrayList([]const u8)) !void {
        if (self.open_index) |index| {
            try frames.append(self.arena, try event(self.arena, "content_block_stop", try std.fmt.allocPrint(self.arena, "{{\"type\":\"content_block_stop\",\"index\":{d}}}", .{index})));
            self.open_index = null;
            self.open_dsh_index = null;
            self.open_kind = null;
            self.adopt_next_text = false;
        }
    }

    /// 喂入一个 Chunk；返回要写出的完整 SSE 帧。
    pub fn write(self: *StreamOut, chunk: types.Chunk) ![]const []const u8 {
        if (self.finished) return &.{};
        // arena 统管内存：返回前不 deinit（与 StreamOut.openai 同因）。
        var frames: std.ArrayList([]const u8) = .empty;

        switch (chunk) {
            // Cline 兼容：chat 专属的路由元数据在 anthropic 形状上无对应概念，忽略（翻译路径丢弃）。
            .provider_metadata => return &.{},
            .text_delta, .reasoning_delta, .tool_delta => {
                if (!self.started) {
                    self.started = true;
                    try frames.append(self.arena, try self.messageStart());
                }
                const dsh_index = switch (chunk) {
                    .text_delta => |delta| delta.index,
                    .reasoning_delta => |delta| delta.index,
                    .tool_delta => |delta| delta.index,
                    else => unreachable,
                };
                const kind: types.BlockKind = switch (chunk) {
                    .text_delta => .text,
                    .reasoning_delta => .reasoning,
                    else => .tool_call,
                };
                // 占位块收养：占位帧开的文本块直接归给下一个真实文本增量（零额外块）。
                const adopting = self.adopt_next_text and kind == .text;
                if (adopting) {
                    self.adopt_next_text = false;
                    self.open_dsh_index = dsh_index;
                }
                if (!adopting and (self.open_index == null or self.open_dsh_index != dsh_index)) {
                    try self.closeOpen(&frames);
                    self.open_index = self.next_index;
                    self.open_dsh_index = dsh_index;
                    self.open_kind = kind;
                    self.next_index += 1;
                    const block_json = switch (kind) {
                        .text => try std.fmt.allocPrint(self.arena, "{{\"type\":\"text\",\"text\":\"\"}}", .{}),
                        .reasoning => try std.fmt.allocPrint(self.arena, "{{\"type\":\"thinking\",\"thinking\":\"\"}}", .{}),
                        .tool_call => blk: {
                            const delta = chunk.tool_delta;
                            break :blk try std.fmt.allocPrint(self.arena, "{{\"type\":\"tool_use\",\"id\":{f},\"name\":{f},\"input\":{{}}}}", .{ std.json.fmt(delta.id, .{}), std.json.fmt(delta.name orelse "", .{}) });
                        },
                    };
                    try frames.append(self.arena, try event(self.arena, "content_block_start", try std.fmt.allocPrint(self.arena, "{{\"type\":\"content_block_start\",\"index\":{d},\"content_block\":{s}}}", .{ self.open_index.?, block_json })));
                }
                const delta_json = switch (chunk) {
                    .text_delta => |delta| try std.fmt.allocPrint(self.arena, "{{\"type\":\"text_delta\",\"text\":{f}}}", .{std.json.fmt(delta.text, .{})}),
                    .reasoning_delta => |delta| try std.fmt.allocPrint(self.arena, "{{\"type\":\"thinking_delta\",\"thinking\":{f}}}", .{std.json.fmt(delta.text, .{})}),
                    .tool_delta => |delta| try std.fmt.allocPrint(self.arena, "{{\"type\":\"input_json_delta\",\"partial_json\":{f}}}", .{std.json.fmt(delta.args_delta, .{})}),
                    else => unreachable,
                };
                if (!(chunk == .tool_delta and chunk.tool_delta.args_delta.len == 0)) {
                    try frames.append(self.arena, try event(self.arena, "content_block_delta", try std.fmt.allocPrint(self.arena, "{{\"type\":\"content_block_delta\",\"index\":{d},\"delta\":{s}}}", .{ self.open_index.?, delta_json })));
                }
            },
            .block_end => {
                if (!self.started) {
                    self.started = true;
                    try frames.append(self.arena, try self.messageStart());
                }
                try self.closeOpen(&frames);
            },
            .usage => |usage| {
                self.input_tokens = usage.input + usage.cache_read + usage.cache_write;
                self.output_tokens = usage.output;
            },
            .finish => |reason| {
                switch (reason) {
                    .failure => |failure| {
                        self.finished = true;
                        try frames.append(self.arena, try event(self.arena, "error", try std.fmt.allocPrint(self.arena, "{{\"type\":\"error\",\"error\":{{\"type\":\"gateway_error\",\"message\":{f},\"code\":{f}}}}}", .{ std.json.fmt(failure.message, .{}), std.json.fmt(failure.code, .{}) })));
                        return frames.items;
                    },
                    else => {},
                }
                self.pending_stop = mapStopToWire(reason);
            },
        }
        return frames.items;
    }

    /// 占位保活（静默时由看门狗调用）。
    /// - 无块打开 → 开一个文本块（并让下一个真实文本增量收养它）；
    /// - 文本块打开中 → 直接追加 delta（零块切换）；
    /// - 工具/思考块打开中 → **跳过**：关块重开会在客户端侧把工具参数拆成两个块、
    ///   并使 thinking 签名失效，宁可不发占位（静默仍由看门狗计时）。
    pub fn writePlaceholder(self: *StreamOut, placeholder_text: []const u8) ![]const []const u8 {
        if (self.finished) return &.{};
        var frames: std.ArrayList([]const u8) = .empty;
        if (self.open_index != null and self.open_kind != .text) return frames.items;
        if (!self.started) {
            self.started = true;
            try frames.append(self.arena, try self.messageStart());
        }
        if (self.open_index == null) {
            self.open_index = self.next_index;
            self.next_index += 1;
            self.open_dsh_index = null;
            self.open_kind = .text;
            self.adopt_next_text = true;
            try frames.append(self.arena, try event(self.arena, "content_block_start", try std.fmt.allocPrint(self.arena, "{{\"type\":\"content_block_start\",\"index\":{d},\"content_block\":{{\"type\":\"text\",\"text\":\"\"}}}}", .{self.open_index.?})));
        }
        try frames.append(self.arena, try event(self.arena, "content_block_delta", try std.fmt.allocPrint(self.arena, "{{\"type\":\"content_block_delta\",\"index\":{d},\"delta\":{{\"type\":\"text_delta\",\"text\":{f}}}}}", .{ self.open_index.?, std.json.fmt(placeholder_text, .{}) })));
        return frames.items;
    }

    pub fn doneEvents(self: *StreamOut) ![]const []const u8 {
        if (self.finished) return &.{};
        self.finished = true;
        var frames: std.ArrayList([]const u8) = .empty;
        if (!self.started) try frames.append(self.arena, try self.messageStart());
        try self.closeOpen(&frames);
        try frames.append(self.arena, try event(self.arena, "message_delta", try std.fmt.allocPrint(self.arena, "{{\"type\":\"message_delta\",\"delta\":{{\"stop_reason\":{f},\"stop_sequence\":null}},\"usage\":{{\"output_tokens\":{d}}}}}", .{
            std.json.fmt(self.pending_stop orelse "end_turn", .{}), self.output_tokens,
        })));
        try frames.append(self.arena, try event(self.arena, "message_stop", "{\"type\":\"message_stop\"}"));
        return frames.items;
    }
};

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------

fn parseObject(arena: std.mem.Allocator, registry: *providers_mod.Registry, body: []const u8) !Parsed {
    const value = try std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{});
    if (value != .object) return error.NotObject;
    return parse(arena, registry, value.object);
}

/// 从 "event: X\ndata: {...}\n\n" 帧里取 data JSON。
fn eventJson(arena: std.mem.Allocator, frame: []const u8) !std.json.Value {
    const marker = "data: ";
    const start = std.mem.indexOf(u8, frame, marker) orelse return error.NoData;
    const payload = std.mem.trimEnd(u8, frame[start + marker.len ..], "\n");
    return std.json.parseFromSliceLeaky(std.json.Value, arena, payload, .{});
}

test "inbound.anthropic parse: 错误集" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var registry = try providers_mod.builtinRegistry(arena);
    defer registry.deinit();

    try std.testing.expectError(error.MissingModel, parseObject(arena, &registry, "{\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]}"));
    try std.testing.expectError(error.MissingMessages, parseObject(arena, &registry, "{\"model\":\"glm-5.3\"}"));
    try std.testing.expectError(error.EmptyRequest, parseObject(arena, &registry, "{\"model\":\"glm-5.3\",\"messages\":[{\"role\":\"user\",\"content\":\"\"}]}"));
    try std.testing.expectError(error.UnknownModel, parseObject(arena, &registry, "{\"model\":\"nope/nope\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]}"));
}

test "inbound.anthropic parse: system/thinking/图片/tool_result 投影" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var registry = try providers_mod.builtinRegistry(arena);
    defer registry.deinit();

    const body =
        \\{"model":"intern-ai/glm-5.3","stream":true,"max_tokens":321,
        \\ "system":[{"type":"text","text":"S1"},{"type":"text","text":"S2"}],
        \\ "thinking":{"type":"enabled","budget_tokens":2000},
        \\ "messages":[
        \\   {"role":"user","content":[{"type":"text","text":"看图"},
        \\     {"type":"image","source":{"type":"base64","media_type":"image/png","data":"AQID"}},
        \\     {"type":"tool_result","tool_use_id":"call_1","content":[{"type":"text","text":"R1"},{"type":"text","text":"R2"}]}]},
        \\   {"role":"assistant","content":[{"type":"tool_use","id":"call_2","name":"fn","input":{"a":1}}]}]}
    ;
    const parsed = try parseObject(arena, &registry, body);
    try std.testing.expect(parsed.stream);
    try std.testing.expectEqual(@as(u64, 321), parsed.request.max_tokens.?);
    try std.testing.expectEqualStrings("S1\nS2", parsed.request.system.?);
    try std.testing.expectEqual(types.Effort.medium, parsed.request.reasoning_effort.?); // 2000 → medium

    // 顺序与 TS 基准一致：扫描 user 消息的 parts 时，tool_result 立即追加 tool 消息，
    // user 消息本体在 parts 扫描完后再追加 → [tool, user, assistant]。
    const messages = parsed.request.messages;
    try std.testing.expectEqual(@as(usize, 3), messages.len);
    // tool_result 拆成 tool 消息（tool_call 占位 + 文本）
    try std.testing.expectEqual(types.Role.tool, messages[0].role);
    try std.testing.expectEqual(@as(usize, 2), messages[0].blocks.len);
    try std.testing.expectEqualStrings("call_1", messages[0].blocks[0].tool_call.id);
    try std.testing.expectEqualStrings("R1\nR2", messages[0].blocks[1].text);
    // user：text + 图片
    try std.testing.expectEqual(types.Role.user, messages[1].role);
    try std.testing.expectEqualStrings("看图", messages[1].blocks[0].text);
    try std.testing.expectEqualStrings("data:image/png;base64,AQID", messages[1].blocks[1].image.data_uri);
    // assistant tool_use：input 对象被序列化为 arguments
    try std.testing.expectEqual(types.Role.assistant, messages[2].role);
    try std.testing.expectEqualStrings("call_2", messages[2].blocks[0].tool_call.id);
    try std.testing.expectEqualStrings("{\"a\":1}", messages[2].blocks[0].tool_call.arguments);
}

test "inbound.anthropic parse: thinking 三态（disabled/budget 阈值）" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var registry = try providers_mod.builtinRegistry(arena);
    defer registry.deinit();

    const base = "{\"model\":\"glm-5.3\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]";
    const disabled = try parseObject(arena, &registry, base ++ ",\"thinking\":{\"type\":\"disabled\"}}");
    try std.testing.expectEqual(types.Effort.off, disabled.request.reasoning_effort.?);
    const low = try parseObject(arena, &registry, base ++ ",\"thinking\":{\"type\":\"enabled\",\"budget_tokens\":100}}");
    try std.testing.expectEqual(types.Effort.low, low.request.reasoning_effort.?);
    const unset = try parseObject(arena, &registry, base ++ ",\"thinking\":{\"type\":\"enabled\"}}");
    try std.testing.expectEqual(types.Effort.medium, unset.request.reasoning_effort.?); // 缺 budget → medium
}

test "inbound.anthropic assembleMessage: 块序/usage/stop_reason" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const chunks = [_]types.Chunk{
        .{ .reasoning_delta = .{ .index = 0, .text = "想" } },
        .{ .text_delta = .{ .index = 1, .text = "答" } },
        .{ .block_end = .{ .index = 2, .block = .{ .tool_call = .{ .id = "call_1", .name = "fn", .arguments = "{\"a\":1}" } } } },
        .{ .usage = .{ .input = 10, .output = 5, .total = 17, .cache_read = 2, .cache_write = 1, .reasoning = 3 } },
        .{ .finish = .tool_calls },
    };
    const body = try assembleMessage(arena, "intern-ai/glm-5.3", &chunks);
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{});
    try std.testing.expectEqualStrings("message", parsed.object.get("type").?.string);
    try std.testing.expectEqualStrings("tool_use", parsed.object.get("stop_reason").?.string);
    const content = parsed.object.get("content").?.array.items;
    try std.testing.expectEqual(@as(usize, 3), content.len);
    try std.testing.expectEqualStrings("thinking", content[0].object.get("type").?.string);
    try std.testing.expectEqualStrings("想", content[0].object.get("thinking").?.string);
    try std.testing.expectEqualStrings("text", content[1].object.get("type").?.string);
    try std.testing.expectEqualStrings("tool_use", content[2].object.get("type").?.string);
    try std.testing.expectEqualStrings("call_1", content[2].object.get("id").?.string);
    const usage = parsed.object.get("usage").?.object;
    try std.testing.expectEqual(@as(i64, 13), usage.get("input_tokens").?.integer);
    try std.testing.expectEqual(@as(i64, 5), usage.get("output_tokens").?.integer);
}

test "inbound.anthropic StreamOut: 块切换/事件序/doneEvents" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var out = StreamOut.init(arena, "m");

    // 首帧：message_start + content_block_start(text) + content_block_delta
    const first = try out.write(.{ .text_delta = .{ .index = 0, .text = "hi" } });
    try std.testing.expectEqual(@as(usize, 3), first.len);
    try std.testing.expect(std.mem.startsWith(u8, first[0], "event: message_start"));
    const start = try eventJson(arena, first[1]);
    try std.testing.expectEqualStrings("content_block_start", start.object.get("type").?.string);
    try std.testing.expectEqualStrings("text", start.object.get("content_block").?.object.get("type").?.string);

    // 切到工具块：先 stop 旧块再 start 新块；空参数 delta 不发 content_block_delta（TS 基准同）
    const tool = try out.write(.{ .tool_delta = .{ .index = 1, .id = "call_1", .name = "fn", .args_delta = "" } });
    try std.testing.expectEqual(@as(usize, 2), tool.len);
    const stop = try eventJson(arena, tool[0]);
    try std.testing.expectEqualStrings("content_block_stop", stop.object.get("type").?.string);
    const tool_start = try eventJson(arena, tool[1]);
    try std.testing.expectEqualStrings("tool_use", tool_start.object.get("content_block").?.object.get("type").?.string);
    try std.testing.expectEqualStrings("call_1", tool_start.object.get("content_block").?.object.get("id").?.string);

    // usage + finish(tool_calls) → message_delta 带 tool_use
    _ = try out.write(.{ .usage = .{ .input = 3, .output = 4, .total = 7, .cache_read = 0, .cache_write = 0, .reasoning = 0 } });
    _ = try out.write(.{ .finish = .tool_calls });
    const tail = try out.doneEvents();
    try std.testing.expectEqual(@as(usize, 3), tail.len); // block_stop + message_delta + message_stop
    const message_delta = try eventJson(arena, tail[1]);
    try std.testing.expectEqualStrings("tool_use", message_delta.object.get("delta").?.object.get("stop_reason").?.string);
    try std.testing.expectEqual(@as(i64, 4), message_delta.object.get("usage").?.object.get("output_tokens").?.integer);
    try std.testing.expect(std.mem.startsWith(u8, tail[2], "event: message_stop"));
    try std.testing.expect(out.finished);
}

test "inbound.anthropic StreamOut: 失败帧" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var out = StreamOut.init(arena, "m");
    const frames = try out.write(.{ .finish = .{ .failure = .{ .code = "RATE_LIMIT", .message = "slow" } } });
    // 与 TS 基准一致：失败只发 event: error 一帧（不补 message_start；HTTP 头已承诺 200+SSE，
    // 客户端以 error 事件收尾是 Anthropic SDK 可接受的惯例）。
    try std.testing.expectEqual(@as(usize, 1), frames.len);
    try std.testing.expect(std.mem.startsWith(u8, frames[0], "event: error"));
    try std.testing.expect(std.mem.indexOf(u8, frames[0], "RATE_LIMIT") != null);
    try std.testing.expectEqual(@as(usize, 0), (try out.write(.{ .text_delta = .{ .index = 0, .text = "x" } })).len);
}

test "占位剥离：system 与文本块（anthropic 入站）" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var registry = try providers_mod.builtinRegistry(arena);
    defer registry.deinit();

    const placeholder = placeholder_mod.text;
    const ellipsis = placeholder_mod.ellipsis;
    const body = try std.fmt.allocPrint(arena, "{{\"model\":\"glm-5.3\",\"max_tokens\":16," ++
        "\"system\":[{{\"type\":\"text\",\"text\":\"{s}规则\"}}]," ++
        "\"messages\":[" ++
        "{{\"role\":\"user\",\"content\":\"问\"}}," ++
        "{{\"role\":\"assistant\",\"content\":[{{\"type\":\"text\",\"text\":\"{s}答，等等{s}补充\"}}]}}," ++
        "{{\"role\":\"user\",\"content\":\"再问\"}}]}}", .{ placeholder, placeholder, ellipsis });

    const parsed = try parseObject(arena, &registry, body);
    try std.testing.expectEqualStrings("规则", parsed.request.system.?);
    try std.testing.expectEqual(@as(usize, 3), parsed.request.messages.len);
    try std.testing.expectEqual(types.Role.assistant, parsed.request.messages[1].role);
    try std.testing.expectEqual(@as(usize, 1), parsed.request.messages[1].blocks.len);
    try std.testing.expectEqualStrings("答，等等\u{2026}补充", parsed.request.messages[1].blocks[0].text);

    const serialized = try @import("../upstream/anthropic.zig").serializeBody(
        arena,
        registry.find("intern-ai").?,
        parsed.request,
    );
    try std.testing.expect(std.mem.indexOf(u8, serialized, placeholder) == null);
    try std.testing.expect(std.mem.indexOf(u8, serialized, "\u{2063}") == null);
}

test "占位帧：anthropic 文本块内追加 / 工具与思考块中途跳过" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const placeholder = @import("../placeholder.zig").text;

    // 场景 1：静默发生在任何内容之前 → 开文本块 + delta；随后真实文本"收养"该块（零额外块切换）
    var fresh = StreamOut.init(arena, "m");
    const first = try fresh.writePlaceholder(placeholder);
    try std.testing.expectEqual(@as(usize, 3), first.len); // message_start + block_start(text) + delta
    try std.testing.expect(std.mem.startsWith(u8, first[0], "event: message_start"));
    const start = try eventJson(arena, first[1]);
    try std.testing.expectEqualStrings("text", start.object.get("content_block").?.object.get("type").?.string);
    const delta = try eventJson(arena, first[2]);
    try std.testing.expectEqualStrings(placeholder, delta.object.get("delta").?.object.get("text").?.string);

    const real = try fresh.write(.{ .text_delta = .{ .index = 7, .text = "答" } });
    try std.testing.expectEqual(@as(usize, 1), real.len); // 收养：只发 delta，无 stop/start
    const real_delta = try eventJson(arena, real[0]);
    try std.testing.expectEqualStrings("text_delta", real_delta.object.get("delta").?.object.get("type").?.string);
    try std.testing.expectEqualStrings("答", real_delta.object.get("delta").?.object.get("text").?.string);

    // 文本块打开中再来占位 → 直接追加（1 帧）
    const again = try fresh.writePlaceholder(placeholder);
    try std.testing.expectEqual(@as(usize, 1), again.len);

    // 场景 2：工具块打开中 → 跳过（不发任何帧，也不关闭工具块）
    var tooling = StreamOut.init(arena, "m");
    const tool_frames = try tooling.write(.{ .tool_delta = .{ .index = 0, .id = "call_1", .name = "fn", .args_delta = "{\"a\"" } });
    try std.testing.expectEqual(@as(usize, 3), tool_frames.len); // message_start + block_start(tool_use) + input_json_delta
    const skipped = try tooling.writePlaceholder(placeholder);
    try std.testing.expectEqual(@as(usize, 0), skipped.len);
    // 工具块仍在：后续参数增量直接进入同一块（无 stop/start）
    const more = try tooling.write(.{ .tool_delta = .{ .index = 0, .id = "call_1", .name = null, .args_delta = ":1}" } });
    try std.testing.expectEqual(@as(usize, 1), more.len);

    // 场景 3：思考块打开中 → 同样跳过（thinking 签名不能被拆块）
    var thinking = StreamOut.init(arena, "m");
    _ = try thinking.write(.{ .reasoning_delta = .{ .index = 0, .text = "想" } });
    try std.testing.expectEqual(@as(usize, 0), (try thinking.writePlaceholder(placeholder)).len);
}
