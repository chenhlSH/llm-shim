//! OpenAI Responses 入站：解析 → GenerateRequest；Chunk → response 对象/SSE 事件。
//! 无状态屏蔽：store/previous_response_id 接受但忽略。
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

    if (body.get("instructions")) |instructions| {
        if (instructions == .string and instructions.string.len > 0) {
            const blocks = try arena.alloc(types.Block, 1);
            blocks[0] = .{ .text = instructions.string };
            try messages.append(arena, .{ .role = .system, .blocks = blocks });
        }
    }

    const raw_input = body.get("input") orelse return error.MissingInput;
    // 字符串 input = 单条 user 消息
    if (raw_input == .string) {
        const blocks = try arena.alloc(types.Block, 1);
        blocks[0] = .{ .text = raw_input.string };
        try messages.append(arena, .{ .role = .user, .blocks = blocks });
    }
    const items: []const std.json.Value = switch (raw_input) {
        .string => &.{},
        .array => |array| array.items,
        else => return error.MissingInput,
    };

    for (items) |raw| {
        if (raw != .object) continue;
        const item = raw.object;
        const item_type = if (item.get("type")) |t| (if (t == .string) t.string else "") else "";

        if (std.mem.eql(u8, item_type, "function_call")) {
            const call_id = item.get("call_id") orelse continue;
            const name = item.get("name") orelse continue;
            if (call_id != .string or name != .string) continue;
            const arguments: []const u8 = if (item.get("arguments")) |value| (if (value == .string) value.string else "{}") else "{}";
            const blocks = try arena.alloc(types.Block, 1);
            blocks[0] = .{ .tool_call = .{ .id = call_id.string, .name = name.string, .arguments = arguments } };
            try messages.append(arena, .{ .role = .assistant, .blocks = blocks });
            continue;
        }
        if (std.mem.eql(u8, item_type, "function_call_output")) {
            const call_id = item.get("call_id") orelse continue;
            if (call_id != .string) continue;
            const output: []const u8 = if (item.get("output")) |value| (if (value == .string) value.string else "(no output)") else "(no output)";
            const blocks = try arena.alloc(types.Block, 2);
            blocks[0] = .{ .tool_call = .{ .id = call_id.string, .name = "", .arguments = "{}" } };
            blocks[1] = .{ .text = output };
            try messages.append(arena, .{ .role = .tool, .blocks = blocks });
            continue;
        }
        if (std.mem.eql(u8, item_type, "reasoning")) continue;

        const role = if (item.get("role")) |value| (if (value == .string) value.string else "user") else "user";
        const is_assistant = std.mem.eql(u8, role, "assistant");
        var blocks: std.ArrayList(types.Block) = .empty;
        const content = item.get("content");
        if (content != null) {
            switch (content.?) {
                .string => |text| {
                    if (text.len > 0) try blocks.append(arena, .{ .text = text });
                },
                .array => |parts| {
                    for (parts.items) |part| {
                        if (part != .object) continue;
                        const kind = part.object.get("type") orelse continue;
                        if (kind != .string) continue;
                        if (std.mem.eql(u8, kind.string, "input_text") or (std.mem.eql(u8, kind.string, "output_text") and is_assistant)) {
                            if (part.object.get("text")) |text| {
                                if (text == .string and text.string.len > 0) {
                                    try blocks.append(arena, .{ .text = text.string });
                                }
                            }
                        } else if (std.mem.eql(u8, kind.string, "input_image")) {
                            const url = part.object.get("image_url") orelse continue;
                            if (url != .string or url.string.len == 0) continue;
                            try blocks.append(arena, .{ .image = .{ .data_uri = url.string } });
                        }
                    }
                },
                else => {},
            }
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
        if (is_assistant) {
            try messages.append(arena, .{ .role = .assistant, .blocks = try blocks.toOwnedSlice(arena) });
        } else {
            try messages.append(arena, .{ .role = .user, .blocks = try blocks.toOwnedSlice(arena) });
        }
    }
    if (messages.items.len == 0) return error.EmptyRequest;

    var tools: ?[]const types.ToolSchema = null;
    if (body.get("tools")) |tools_value| {
        if (tools_value == .array and tools_value.array.items.len > 0) {
            var tool_list: std.ArrayList(types.ToolSchema) = .empty;
            for (tools_value.array.items) |raw_tool| {
                if (raw_tool != .object) continue;
                const kind = raw_tool.object.get("type") orelse continue;
                if (kind != .string or !std.mem.eql(u8, kind.string, "function")) continue;
                const name = raw_tool.object.get("name") orelse continue;
                if (name != .string) continue;
                const description: []const u8 = if (raw_tool.object.get("description")) |value| switch (value) {
                    .string => |text| text,
                    else => "",
                } else "";
                const parameters: std.json.Value = raw_tool.object.get("parameters") orelse try std.json.parseFromSliceLeaky(std.json.Value, arena, "{\"type\":\"object\",\"properties\":{}}", .{});
                try tool_list.append(arena, .{ .name = name.string, .description = description, .parameters = parameters });
            }
            if (tool_list.items.len > 0) tools = try tool_list.toOwnedSlice(arena);
        }
    }

    var reasoning_effort: ?types.Effort = null;
    if (body.get("reasoning")) |reasoning| {
        if (reasoning == .object) {
            if (reasoning.object.get("effort")) |effort| {
                if (effort == .string) reasoning_effort = effort_mod.normalizeInbound(effort.string);
            }
        }
    }

    var max_tokens: ?u64 = null;
    if (body.get("max_output_tokens")) |value| {
        if (value == .integer and value.integer > 0) max_tokens = @intCast(value.integer);
    }

    return .{
        .request = .{
            .provider = resolved.profile.name,
            .model = resolved.model,
            .messages = try placeholder_mod.stripFromMessages(arena, try messages.toOwnedSlice(arena)),
            .reasoning_effort = reasoning_effort,
            .tools = tools,
            .max_tokens = max_tokens,
        },
        .stream = if (body.get("stream")) |value| value == .bool and value.bool else false,
        .model_echo = model_echo,
    };
}

// ---------------------------------------------------------------------------
// 组装 + 流式发射（TS: assembleResponsesResponse / ResponsesStreamOut）
// ---------------------------------------------------------------------------

pub fn assembleResponse(arena: std.mem.Allocator, model_echo: []const u8, chunks: []const types.Chunk) ![]const u8 {
    var reasoning: std.ArrayList(u8) = .empty;
    var text: std.ArrayList(u8) = .empty;
    var tool_calls: std.ArrayList(u8) = .empty;
    var input_tokens: u64 = 0;
    var output_tokens: u64 = 0;
    var incomplete = false;

    for (chunks) |chunk| {
        switch (chunk) {
            .text_delta => |delta| try text.appendSlice(arena, delta.text),
            .reasoning_delta => |delta| try reasoning.appendSlice(arena, delta.text),
            .block_end => |end| {
                if (end.block == .tool_call) {
                    const call = end.block.tool_call;
                    const part = try std.fmt.allocPrint(arena, "{{\"type\":\"function_call\",\"id\":{f},\"call_id\":{f},\"name\":{f},\"arguments\":{f},\"status\":\"completed\"}}", .{
                        std.json.fmt(call.id, .{}), std.json.fmt(call.id, .{}), std.json.fmt(call.name, .{}), std.json.fmt(call.arguments, .{}),
                    });
                    if (tool_calls.items.len > 0) try tool_calls.append(arena, ',');
                    try tool_calls.appendSlice(arena, part);
                }
            },
            .usage => |usage| {
                input_tokens = usage.input + usage.cache_read + usage.cache_write;
                output_tokens = usage.output;
            },
            .finish => |reason| {
                if (reason == .max_tokens) incomplete = true;
            },
            else => {},
        }
    }

    var output_items: std.ArrayList(u8) = .empty;
    if (reasoning.items.len > 0) {
        const part = try std.fmt.allocPrint(arena, "{{\"id\":\"rs_0\",\"type\":\"reasoning\",\"role\":\"assistant\",\"summary\":[{{\"type\":\"summary_text\",\"text\":{f}}}]}}", .{std.json.fmt(reasoning.items, .{})});
        if (output_items.items.len > 0) try output_items.append(arena, ',');
        try output_items.appendSlice(arena, part);
    }
    if (tool_calls.items.len > 0) {
        if (output_items.items.len > 0) try output_items.append(arena, ',');
        try output_items.appendSlice(arena, tool_calls.items);
    }
    if (text.items.len > 0 or tool_calls.items.len == 0) {
        const part = try std.fmt.allocPrint(arena, "{{\"id\":\"msg_0\",\"type\":\"message\",\"role\":\"assistant\",\"status\":\"completed\",\"content\":[{{\"type\":\"output_text\",\"text\":{f},\"annotations\":[]}}]}}", .{std.json.fmt(text.items, .{})});
        if (output_items.items.len > 0) try output_items.append(arena, ',');
        try output_items.appendSlice(arena, part);
    }

    return std.fmt.allocPrint(arena, "{{\"id\":\"resp_{d}_{d}\",\"object\":\"response\",\"created_at\":{d},\"status\":{s},\"model\":{f},\"output\":[{s}],\"usage\":{{\"input_tokens\":{d},\"output_tokens\":{d},\"total_tokens\":{d}}}}}", .{
        clock.unixMilli(),                                     @rem(clock.unixMilli(), 1_000_000), @divTrunc(clock.unixMilli(), 1000),
        if (incomplete) "\"incomplete\"" else "\"completed\"", std.json.fmt(model_echo, .{}),
        output_items.items,                                    input_tokens,
        output_tokens,                                         input_tokens + output_tokens,
    });
}

/// 流式发射器（TS: ResponsesStreamOut）。
/// 按 IR block index 跟踪 output item：text/reasoning 保持"开新类先关旧"的顺序语义；
/// 工具调用按 index 各自成一个 output item（支持并行多工具、零参数工具不丢）。
pub const StreamOut = struct {
    arena: std.mem.Allocator,
    model_echo: []const u8,
    /// 下一个 output item 的 output_index（每开一个 item 递增）。
    next_output_index: usize = 0,
    /// text/reasoning：至多一个（kind 切换时先关旧，保持"消息项先 done"的顺序）。
    open_nontool: ?NonToolItem = null,
    /// tool_call：按 IR block index 各自成一 output item。
    open_tools: std.AutoHashMapUnmanaged(usize, ToolItem) = .empty,
    started: bool = false,
    finished: bool = false,
    input_tokens: u64 = 0,
    output_tokens: u64 = 0,
    pending_completed: ?[]const u8 = null,
    /// 一次响应的身份：created/completed/failed 共用（客户端拿到的 id 不中途换人）。
    response_id: ?[]const u8 = null,
    /// output item 的稳定 id 序列（msg_/rs_ 前缀；客户端按 item_id 归并增量）。
    next_item_seq: usize = 0,

    const NonToolItem = struct {
        kind: types.BlockKind,
        output_index: usize,
        item_id: []const u8 = "",
    };

    const ToolItem = struct {
        output_index: usize,
        id: []const u8 = "",
        name: []const u8 = "",
        /// 参数增量累积（畸形流没有 block_end 时用它兜底 done 事件）。
        args: std.ArrayList(u8) = .empty,
    };

    pub fn init(arena: std.mem.Allocator, model_echo: []const u8) StreamOut {
        return .{ .arena = arena, .model_echo = model_echo };
    }

    fn event(arena: std.mem.Allocator, name: []const u8, payload: []const u8) ![]const u8 {
        return std.fmt.allocPrint(arena, "event: {s}\ndata: {s}\n\n", .{ name, payload });
    }

    fn id(self: *StreamOut) ![]const u8 {
        if (self.response_id) |existing| return existing;
        const generated = try std.fmt.allocPrint(self.arena, "resp_{d}", .{clock.unixMilli()});
        self.response_id = generated;
        return generated;
    }

    fn created(self: *StreamOut) ![]const u8 {
        return event(self.arena, "response.created", try std.fmt.allocPrint(self.arena, "{{\"type\":\"response.created\",\"response\":{{\"id\":\"{s}\",\"object\":\"response\",\"created_at\":{d},\"status\":\"in_progress\",\"model\":{f},\"output\":[],\"usage\":{{\"input_tokens\":{d},\"output_tokens\":0}}}}}}", .{
            try self.id(), @divTrunc(clock.unixMilli(), 1000), std.json.fmt(self.model_echo, .{}), self.input_tokens,
        }));
    }

    /// 新 output item 的稳定 id（msg_0 / rs_1 …；客户端靠它在增量事件里认领 item）。
    fn newItemId(self: *StreamOut, prefix: []const u8) ![]const u8 {
        const generated = try std.fmt.allocPrint(self.arena, "{s}_{d}", .{ prefix, self.next_item_seq });
        self.next_item_seq += 1;
        return generated;
    }

    /// 失败事件（规范形状）：完整 Response 对象（id/object/status/model/output/error/usage），
    /// created/completed/failed 同 id；`status: "failed"` + `error` 是客户端识别失败的唯一依据。
    pub fn failedEvent(self: *StreamOut, code: []const u8, message: []const u8) ![]const u8 {
        return event(self.arena, "response.failed", try std.fmt.allocPrint(self.arena, "{{\"type\":\"response.failed\",\"response\":{{\"id\":\"{s}\",\"object\":\"response\",\"created_at\":{d},\"status\":\"failed\",\"model\":{f},\"output\":[],\"error\":{{\"code\":{f},\"message\":{f},\"type\":\"gateway_error\"}},\"usage\":{{\"input_tokens\":{d},\"output_tokens\":{d},\"total_tokens\":{d}}}}}}}", .{
            try self.id(), @divTrunc(clock.unixMilli(), 1000), std.json.fmt(self.model_echo, .{}), std.json.fmt(code, .{}), std.json.fmt(message, .{}),
            self.input_tokens, self.output_tokens, self.input_tokens + self.output_tokens,
        }));
    }

    fn ensureStarted(self: *StreamOut, frames: *std.ArrayList([]const u8)) !void {
        if (self.started) return;
        self.started = true;
        try frames.append(self.arena, try self.created());
    }

    /// item JSON：**必须带 `id`**（客户端逐事件 schema 校验，缺 id 的事件会被整条丢弃）。
    /// done 时 message/reasoning 带 status=completed；function_call 的 done 还要求 status 字段。
    fn itemJson(self: *StreamOut, kind: types.BlockKind, tool: ?types.ToolCall, item_id: []const u8, done: bool) ![]const u8 {
        const status: []const u8 = if (done) "\"completed\"" else "\"in_progress\"";
        return switch (kind) {
            .text => try std.fmt.allocPrint(self.arena, "{{\"id\":{f},\"type\":\"message\",\"role\":\"assistant\",\"status\":{s}}}", .{ std.json.fmt(item_id, .{}), status }),
            .reasoning => try std.fmt.allocPrint(self.arena, "{{\"id\":{f},\"type\":\"reasoning\",\"role\":\"assistant\",\"status\":{s}}}", .{ std.json.fmt(item_id, .{}), status }),
            .tool_call => blk: {
                const call = tool orelse types.ToolCall{ .id = item_id, .name = "", .arguments = "" };
                if (done) {
                    break :blk try std.fmt.allocPrint(self.arena, "{{\"id\":{f},\"type\":\"function_call\",\"role\":\"assistant\",\"call_id\":{f},\"name\":{f},\"arguments\":{f},\"status\":\"completed\"}}", .{
                        std.json.fmt(item_id, .{}), std.json.fmt(call.id, .{}), std.json.fmt(call.name, .{}), std.json.fmt(call.arguments, .{}),
                    });
                }
                break :blk try std.fmt.allocPrint(self.arena, "{{\"id\":{f},\"type\":\"function_call\",\"role\":\"assistant\",\"call_id\":{f},\"name\":{f},\"arguments\":{f}}}", .{
                    std.json.fmt(item_id, .{}), std.json.fmt(call.id, .{}), std.json.fmt(call.name, .{}), std.json.fmt(call.arguments, .{}),
                });
            },
        };
    }

    fn addedFrame(self: *StreamOut, frames: *std.ArrayList([]const u8), output_index: usize, item_json: []const u8) !void {
        try frames.append(self.arena, try event(self.arena, "response.output_item.added", try std.fmt.allocPrint(self.arena, "{{\"type\":\"response.output_item.added\",\"output_index\":{d},\"item\":{s}}}", .{ output_index, item_json })));
    }

    fn doneFrame(self: *StreamOut, frames: *std.ArrayList([]const u8), output_index: usize, item_json: []const u8) !void {
        try frames.append(self.arena, try event(self.arena, "response.output_item.done", try std.fmt.allocPrint(self.arena, "{{\"type\":\"response.output_item.done\",\"output_index\":{d},\"item\":{s}}}", .{ output_index, item_json })));
    }

    fn closeNonTool(self: *StreamOut, frames: *std.ArrayList([]const u8)) !void {
        if (self.open_nontool) |item| {
            try self.doneFrame(frames, item.output_index, try self.itemJson(item.kind, null, item.item_id, true));
            self.open_nontool = null;
        }
    }

    fn closeNonToolKind(self: *StreamOut, frames: *std.ArrayList([]const u8), kind: types.BlockKind) !void {
        if (self.open_nontool) |item| {
            if (item.kind == kind) {
                try self.doneFrame(frames, item.output_index, try self.itemJson(kind, null, item.item_id, true));
                self.open_nontool = null;
            }
        }
    }

    /// 打开/复用 text/reasoning item；kind 切换时先关旧（消息项先 done，与官方事件序一致）。
    fn openNonTool(self: *StreamOut, frames: *std.ArrayList([]const u8), kind: types.BlockKind) !usize {
        if (self.open_nontool) |item| {
            if (item.kind == kind) return item.output_index;
            try self.closeNonTool(frames);
        }
        const output_index = self.next_output_index;
        self.next_output_index += 1;
        const item_id = try self.newItemId(if (kind == .text) "msg" else "rs");
        self.open_nontool = .{ .kind = kind, .output_index = output_index, .item_id = item_id };
        try self.addedFrame(frames, output_index, try self.itemJson(kind, null, item_id, false));
        return output_index;
    }

    pub fn write(self: *StreamOut, chunk: types.Chunk) ![]const []const u8 {
        if (self.finished) return &.{};
        var frames: std.ArrayList([]const u8) = .empty;

        switch (chunk) {
            // Cline 兼容：chat 专属的路由元数据在 responses 形状上无对应概念，忽略（翻译路径丢弃）。
            .provider_metadata => return &.{},
            .text_delta => |delta| {
                try self.ensureStarted(&frames);
                const output_index = try self.openNonTool(&frames, .text);
                try frames.append(self.arena, try event(self.arena, "response.output_text.delta", try std.fmt.allocPrint(self.arena, "{{\"type\":\"response.output_text.delta\",\"item_id\":{f},\"output_index\":{d},\"content_index\":0,\"delta\":{f}}}", .{ std.json.fmt(self.open_nontool.?.item_id, .{}), output_index, std.json.fmt(delta.text, .{}) })));
            },
            .reasoning_delta => |delta| {
                try self.ensureStarted(&frames);
                const output_index = try self.openNonTool(&frames, .reasoning);
                try frames.append(self.arena, try event(self.arena, "response.reasoning_summary_text.delta", try std.fmt.allocPrint(self.arena, "{{\"type\":\"response.reasoning_summary_text.delta\",\"item_id\":{f},\"output_index\":{d},\"summary_index\":0,\"delta\":{f}}}", .{ std.json.fmt(self.open_nontool.?.item_id, .{}), output_index, std.json.fmt(delta.text, .{}) })));
            },
            .tool_delta => |delta| {
                try self.ensureStarted(&frames);
                const gop = try self.open_tools.getOrPut(self.arena, delta.index);
                if (!gop.found_existing) {
                    // 消息项先 done、工具项后 added；工具之间互不关闭（并行多工具各占一个 item）
                    try self.closeNonTool(&frames);
                    const output_index = self.next_output_index;
                    self.next_output_index += 1;
                    gop.value_ptr.* = .{ .output_index = output_index };
                    try self.addedFrame(&frames, output_index, try self.itemJson(.tool_call, .{ .id = delta.id, .name = delta.name orelse "", .arguments = "" }, delta.id, false));
                }
                const item = gop.value_ptr;
                if (delta.id.len > 0) item.id = delta.id;
                if (delta.name) |name| {
                    if (name.len > 0) item.name = name;
                }
                if (delta.args_delta.len > 0) {
                    try item.args.appendSlice(self.arena, delta.args_delta);
                    try frames.append(self.arena, try event(self.arena, "response.function_call_arguments.delta", try std.fmt.allocPrint(self.arena, "{{\"type\":\"response.function_call_arguments.delta\",\"item_id\":{f},\"output_index\":{d},\"delta\":{f}}}", .{ std.json.fmt(item.id, .{}), item.output_index, std.json.fmt(delta.args_delta, .{}) })));
                }
            },
            .block_end => |end| {
                try self.ensureStarted(&frames);
                switch (end.block) {
                    .text => try self.closeNonToolKind(&frames, .text),
                    .reasoning => try self.closeNonToolKind(&frames, .reasoning),
                    .image => {},
                    .tool_call => |call| {
                        if (self.open_tools.fetchRemove(end.index)) |removed| {
                            try self.doneFrame(&frames, removed.value.output_index, try self.itemJson(.tool_call, call, call.id, true));
                        } else {
                            // 零参数/未见 delta 的工具：补发 added+done（否则整条丢失）
                            try self.closeNonTool(&frames);
                            const output_index = self.next_output_index;
                            self.next_output_index += 1;
                            try self.addedFrame(&frames, output_index, try self.itemJson(.tool_call, .{ .id = call.id, .name = call.name, .arguments = "" }, call.id, false));
                            try self.doneFrame(&frames, output_index, try self.itemJson(.tool_call, call, call.id, true));
                        }
                    },
                }
            },
            .usage => |usage| {
                self.input_tokens = usage.input + usage.cache_read + usage.cache_write;
                self.output_tokens = usage.output;
            },
            .finish => |reason| {
                switch (reason) {
                    .failure => |failure| {
                        self.finished = true;
                        try frames.append(self.arena, try self.failedEvent(failure.code, failure.message));
                        return frames.items;
                    },
                    else => {},
                }
                const status: []const u8 = if (reason == .max_tokens) "\"incomplete\"" else "\"completed\"";
                self.pending_completed = try event(self.arena, "response.completed", try std.fmt.allocPrint(self.arena, "{{\"type\":\"response.completed\",\"response\":{{\"id\":\"{s}\",\"object\":\"response\",\"created_at\":{d},\"status\":{s},\"model\":{f},\"usage\":{{\"input_tokens\":{d},\"output_tokens\":{d},\"total_tokens\":{d}}}}}}}", .{
                    try self.id(), @divTrunc(clock.unixMilli(), 1000), status, std.json.fmt(self.model_echo, .{}), self.input_tokens, self.output_tokens, self.input_tokens + self.output_tokens,
                }));
            },
        }
        return frames.items;
    }

    /// 占位保活（静默时由看门狗调用）：responses 的文本增量复用已开的 message item，
    /// 与真实回答在同一 item 内拼接，不新增 output_index。
    pub fn writePlaceholder(self: *StreamOut, placeholder_text: []const u8) ![]const []const u8 {
        return self.write(.{ .text_delta = .{ .index = 0, .text = placeholder_text } });
    }

    pub fn doneEvents(self: *StreamOut) ![]const []const u8 {
        if (self.finished) return &.{};
        self.finished = true;
        var frames: std.ArrayList([]const u8) = .empty;
        try self.ensureStarted(&frames);
        // 兜底关闭仍开的 item（正常流里 block_end 已全部关闭）
        try self.closeNonTool(&frames);
        if (self.open_tools.count() > 0) {
            const Pending = struct { output_index: usize, block_index: usize };
            var pending: std.ArrayList(Pending) = .empty;
            var iterator = self.open_tools.iterator();
            while (iterator.next()) |entry| {
                try pending.append(self.arena, .{ .output_index = entry.value_ptr.output_index, .block_index = entry.key_ptr.* });
            }
            std.mem.sort(Pending, pending.items, {}, struct {
                fn lessThan(_: void, a: Pending, b: Pending) bool {
                    return a.output_index < b.output_index;
                }
            }.lessThan);
            for (pending.items) |entry| {
                const item = self.open_tools.getPtr(entry.block_index) orelse continue;
                try self.doneFrame(&frames, item.output_index, try self.itemJson(.tool_call, .{ .id = item.id, .name = item.name, .arguments = item.args.items }, item.id, true));
            }
            self.open_tools.clearRetainingCapacity();
        }
        if (self.pending_completed) |completed| {
            try frames.append(self.arena, completed);
        } else {
            try frames.append(self.arena, try event(self.arena, "response.completed", try std.fmt.allocPrint(self.arena, "{{\"type\":\"response.completed\",\"response\":{{\"id\":\"{s}\",\"object\":\"response\",\"created_at\":{d},\"status\":\"completed\",\"model\":{f},\"usage\":{{\"input_tokens\":{d},\"output_tokens\":{d},\"total_tokens\":{d}}}}}}}", .{
                try self.id(), @divTrunc(clock.unixMilli(), 1000), std.json.fmt(self.model_echo, .{}), self.input_tokens, self.output_tokens, self.input_tokens + self.output_tokens,
            })));
        }
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

fn eventName(frame: []const u8) []const u8 {
    std.debug.assert(std.mem.startsWith(u8, frame, "event: "));
    const rest = frame["event: ".len..];
    const end = std.mem.indexOfScalar(u8, rest, '\n') orelse rest.len;
    return rest[0..end];
}

fn itemOutputIndex(frame: []const u8) i64 {
    const rest = frame["event: ".len..];
    const marker = "\"output_index\":";
    const start = std.mem.indexOf(u8, rest, marker).? + marker.len;
    var end = start;
    while (end < rest.len and std.ascii.isDigit(rest[end])) end += 1;
    return std.fmt.parseInt(i64, rest[start..end], 10) catch -1;
}

fn itemJsonOf(arena: std.mem.Allocator, frame: []const u8) !std.json.Value {
    const payload = try eventJson(arena, frame);
    return payload.object.get("item").?;
}

test "inbound.responses parse: 错误集与无状态屏蔽" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var registry = try providers_mod.builtinRegistry(arena);
    defer registry.deinit();

    try std.testing.expectError(error.MissingModel, parseObject(arena, &registry, "{\"input\":\"hi\"}"));
    try std.testing.expectError(error.MissingInput, parseObject(arena, &registry, "{\"model\":\"glm-5.3\"}"));
    try std.testing.expectError(error.EmptyRequest, parseObject(arena, &registry, "{\"model\":\"glm-5.3\",\"input\":[]}"));
    try std.testing.expectError(error.UnknownModel, parseObject(arena, &registry, "{\"model\":\"nope/nope\",\"input\":\"hi\"}"));

    // store/previous_response_id 接受但忽略（不进 IR）
    const stateless = try parseObject(arena, &registry, "{\"model\":\"glm-5.3\",\"input\":\"hi\",\"store\":true,\"previous_response_id\":\"resp_x\"}");
    try std.testing.expectEqualStrings("hi", stateless.request.messages[0].blocks[0].text);
}

test "inbound.responses parse: instructions/items 回放/字段" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var registry = try providers_mod.builtinRegistry(arena);
    defer registry.deinit();

    const body =
        \\{"model":"intern-ai/glm-5.3","stream":true,"max_output_tokens":77,
        \\ "instructions":"你是助手",
        \\ "reasoning":{"effort":"high"},
        \\ "input":[
        \\   {"type":"message","role":"user","content":[{"type":"input_text","text":"问"},{"type":"input_image","image_url":"data:image/png;base64,AQID"}]},
        \\   {"type":"function_call","call_id":"call_1","name":"fn","arguments":"{\"a\":1}"},
        \\   {"type":"function_call_output","call_id":"call_1","output":"ok"},
        \\   {"type":"reasoning","id":"rs_1"},
        \\   {"type":"message","role":"assistant","content":[{"type":"output_text","text":"答"},{"type":"input_text","text":"不应出现"}]}],
        \\ "tools":[{"type":"function","name":"fn","description":"d"}]}
    ;
    const parsed = try parseObject(arena, &registry, body);
    try std.testing.expectEqual(@as(u64, 77), parsed.request.max_tokens.?);
    try std.testing.expectEqual(types.Effort.high, parsed.request.reasoning_effort.?);
    try std.testing.expectEqualStrings("fn", parsed.request.tools.?[0].name);

    const messages = parsed.request.messages;
    // system + user + assistant(function_call) + tool(function_call_output) + assistant(output_text)；reasoning 被跳过
    try std.testing.expectEqual(@as(usize, 5), messages.len);
    try std.testing.expectEqual(types.Role.system, messages[0].role);
    try std.testing.expectEqualStrings("你是助手", messages[0].blocks[0].text);
    try std.testing.expectEqual(types.Role.user, messages[1].role);
    try std.testing.expectEqualStrings("问", messages[1].blocks[0].text);
    try std.testing.expectEqualStrings("data:image/png;base64,AQID", messages[1].blocks[1].image.data_uri);
    try std.testing.expectEqual(types.Role.assistant, messages[2].role);
    try std.testing.expectEqualStrings("call_1", messages[2].blocks[0].tool_call.id);
    try std.testing.expectEqual(types.Role.tool, messages[3].role);
    try std.testing.expectEqualStrings("ok", messages[3].blocks[1].text);
    // 最后一条 assistant：output_text 与 input_text 都收（与 TS 基准一致——
    // input_text 不限角色、output_text 仅 assistant；agent 回放历史常用 input_text 统一文本 part）
    try std.testing.expectEqualStrings("答", messages[4].blocks[0].text);
    try std.testing.expectEqualStrings("不应出现", messages[4].blocks[1].text);
    try std.testing.expectEqual(@as(usize, 2), messages[4].blocks.len);
}

test "inbound.responses assembleResponse: 输出项顺序/incomplete/usage" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const chunks = [_]types.Chunk{
        .{ .reasoning_delta = .{ .index = 0, .text = "想" } },
        .{ .text_delta = .{ .index = 1, .text = "答" } },
        .{ .block_end = .{ .index = 2, .block = .{ .tool_call = .{ .id = "call_1", .name = "fn", .arguments = "{}" } } } },
        .{ .usage = .{ .input = 4, .output = 6, .total = 10, .cache_read = 0, .cache_write = 0, .reasoning = 0 } },
        .{ .finish = .max_tokens },
    };
    const body = try assembleResponse(arena, "intern-ai/glm-5.3", &chunks);
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{});
    try std.testing.expectEqualStrings("incomplete", parsed.object.get("status").?.string);
    const output = parsed.object.get("output").?.array.items;
    try std.testing.expectEqual(@as(usize, 3), output.len);
    try std.testing.expectEqualStrings("reasoning", output[0].object.get("type").?.string);
    try std.testing.expectEqualStrings("想", output[0].object.get("summary").?.array.items[0].object.get("text").?.string);
    try std.testing.expectEqualStrings("function_call", output[1].object.get("type").?.string);
    try std.testing.expectEqualStrings("call_1", output[1].object.get("id").?.string);
    try std.testing.expectEqualStrings("message", output[2].object.get("type").?.string);
    const usage = parsed.object.get("usage").?.object;
    try std.testing.expectEqual(@as(i64, 4), usage.get("input_tokens").?.integer);
    try std.testing.expectEqual(@as(i64, 10), usage.get("total_tokens").?.integer);
}

test "inbound.responses StreamOut: 文本块与事件序" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var out = StreamOut.init(arena, "m");

    const first = try out.write(.{ .text_delta = .{ .index = 0, .text = "hi" } });
    try std.testing.expectEqual(@as(usize, 3), first.len); // created + added + delta
    try std.testing.expectEqualStrings("response.created", eventName(first[0]));
    try std.testing.expectEqualStrings("response.output_item.added", eventName(first[1]));
    try std.testing.expectEqualStrings("message", (try itemJsonOf(arena, first[1])).object.get("type").?.string);
    try std.testing.expectEqual(@as(i64, 0), itemOutputIndex(first[1]));

    const end = try out.write(.{ .block_end = .{ .index = 0, .block = .{ .text = "hi" } } });
    try std.testing.expectEqual(@as(usize, 1), end.len);
    try std.testing.expectEqualStrings("response.output_item.done", eventName(end[0]));
    try std.testing.expectEqual(@as(i64, 0), itemOutputIndex(end[0]));

    const tail = try out.doneEvents();
    try std.testing.expectEqual(@as(usize, 1), tail.len);
    try std.testing.expectEqualStrings("response.completed", eventName(tail[0]));
    try std.testing.expect(out.finished);
}

test "inbound.responses StreamOut: 规范字段（created_at / item id / item_id）" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var out = StreamOut.init(arena, "m");
    const frames = try out.write(.{ .text_delta = .{ .index = 0, .text = "hi" } });
    const created = try eventJson(arena, frames[0]);
    try std.testing.expect(created.object.get("response").?.object.get("created_at").? == .integer);
    const added = try eventJson(arena, frames[1]);
    try std.testing.expectEqualStrings("msg_0", added.object.get("item").?.object.get("id").?.string);
    const delta = try eventJson(arena, frames[2]);
    try std.testing.expectEqualStrings("msg_0", delta.object.get("item_id").?.string);
    try std.testing.expectEqual(@as(i64, 0), delta.object.get("content_index").?.integer);

    var reasoning_out = StreamOut.init(arena, "m");
    const rframes = try reasoning_out.write(.{ .reasoning_delta = .{ .index = 0, .text = "想" } });
    const rdelta = try eventJson(arena, rframes[2]);
    try std.testing.expectEqualStrings("rs_0", rdelta.object.get("item_id").?.string);
    try std.testing.expectEqual(@as(i64, 0), rdelta.object.get("summary_index").?.integer);
}

test "inbound.responses StreamOut: 单工具 done 带全字段 + 消息项先 done" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var out = StreamOut.init(arena, "m");

    _ = try out.write(.{ .text_delta = .{ .index = 0, .text = "先说一句" } });
    const open_tool = try out.write(.{ .tool_delta = .{ .index = 1, .id = "call_1", .name = "get_weather", .args_delta = "{\"city\":" } });
    // 消息项先 done、工具项后 added，随后是参数增量帧
    try std.testing.expectEqual(@as(usize, 3), open_tool.len);
    try std.testing.expectEqualStrings("response.output_item.done", eventName(open_tool[0]));
    try std.testing.expectEqual(@as(i64, 0), itemOutputIndex(open_tool[0]));
    try std.testing.expectEqualStrings("response.output_item.added", eventName(open_tool[1]));
    const added_item = try itemJsonOf(arena, open_tool[1]);
    try std.testing.expectEqualStrings("call_1", added_item.object.get("id").?.string);
    try std.testing.expectEqualStrings("get_weather", added_item.object.get("name").?.string);
    try std.testing.expectEqualStrings("", added_item.object.get("arguments").?.string);

    const done = try out.write(.{ .block_end = .{ .index = 1, .block = .{ .tool_call = .{ .id = "call_1", .name = "get_weather", .arguments = "{\"city\":\"SF\"}" } } } });
    try std.testing.expectEqual(@as(usize, 1), done.len);
    const done_item = try itemJsonOf(arena, done[0]);
    try std.testing.expectEqualStrings("call_1", done_item.object.get("id").?.string);
    try std.testing.expectEqualStrings("call_1", done_item.object.get("call_id").?.string);
    try std.testing.expectEqualStrings("get_weather", done_item.object.get("name").?.string);
    try std.testing.expectEqualStrings("{\"city\":\"SF\"}", done_item.object.get("arguments").?.string);
}

test "inbound.responses StreamOut: 并行双工具各占一个 output item" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var out = StreamOut.init(arena, "m");

    // 交错增量：idx0、idx1、idx0、idx1
    const f1 = try out.write(.{ .tool_delta = .{ .index = 0, .id = "call_1", .name = "get_weather", .args_delta = "{\"city\":" } });
    const f2 = try out.write(.{ .tool_delta = .{ .index = 1, .id = "call_2", .name = "get_time", .args_delta = "{\"tz\":" } });
    const f3 = try out.write(.{ .tool_delta = .{ .index = 0, .id = "call_1", .name = null, .args_delta = "\"SF\"}" } });
    const f4 = try out.write(.{ .tool_delta = .{ .index = 1, .id = "call_2", .name = null, .args_delta = "\"UTC\"}" } });

    const added0 = (try itemJsonOf(arena, f1[1]));
    const added1 = (try itemJsonOf(arena, f2[0]));
    try std.testing.expectEqual(@as(i64, 0), itemOutputIndex(f1[1]));
    try std.testing.expectEqual(@as(i64, 1), itemOutputIndex(f2[0])); // 第二个工具另占一个 item
    try std.testing.expectEqualStrings("call_1", added0.object.get("id").?.string);
    try std.testing.expectEqualStrings("call_2", added1.object.get("id").?.string);
    try std.testing.expectEqualStrings("get_time", added1.object.get("name").?.string);
    // 后续增量各归各的 item（不串）
    try std.testing.expect(std.mem.indexOf(u8, f3[0], "\"output_index\":0") != null);
    try std.testing.expect(std.mem.indexOf(u8, f4[0], "\"output_index\":1") != null);

    const done0 = try out.write(.{ .block_end = .{ .index = 0, .block = .{ .tool_call = .{ .id = "call_1", .name = "get_weather", .arguments = "{\"city\":\"SF\"}" } } } });
    const done1 = try out.write(.{ .block_end = .{ .index = 1, .block = .{ .tool_call = .{ .id = "call_2", .name = "get_time", .arguments = "{\"tz\":\"UTC\"}" } } } });
    const item0 = try itemJsonOf(arena, done0[0]);
    const item1 = try itemJsonOf(arena, done1[0]);
    try std.testing.expectEqual(@as(i64, 0), itemOutputIndex(done0[0]));
    try std.testing.expectEqual(@as(i64, 1), itemOutputIndex(done1[0]));
    try std.testing.expectEqualStrings("{\"city\":\"SF\"}", item0.object.get("arguments").?.string);
    try std.testing.expectEqualStrings("{\"tz\":\"UTC\"}", item1.object.get("arguments").?.string);
}

test "inbound.responses StreamOut: 零参数工具补发 added+done + 兜底关闭" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // 零参数：没有 tool_delta，直接 block_end
    var out = StreamOut.init(arena, "m");
    const frames = try out.write(.{ .block_end = .{ .index = 7, .block = .{ .tool_call = .{ .id = "call_9", .name = "noop", .arguments = "{}" } } } });
    try std.testing.expectEqual(@as(usize, 3), frames.len); // created + added + done
    try std.testing.expectEqualStrings("response.output_item.added", eventName(frames[1]));
    try std.testing.expectEqualStrings("response.output_item.done", eventName(frames[2]));
    const item = try itemJsonOf(arena, frames[2]);
    try std.testing.expectEqualStrings("call_9", item.object.get("id").?.string);
    try std.testing.expectEqualStrings("noop", item.object.get("name").?.string);
    try std.testing.expectEqualStrings("{}", item.object.get("arguments").?.string);

    // 畸形流（没有 block_end）：doneEvents 按缓存状态兜底
    var leftover = StreamOut.init(arena, "m");
    _ = try leftover.write(.{ .tool_delta = .{ .index = 0, .id = "c1", .name = "fn", .args_delta = "{\"a\":1}" } });
    const tail = try leftover.doneEvents();
    try std.testing.expectEqual(@as(usize, 2), tail.len); // done + completed
    const leftover_item = try itemJsonOf(arena, tail[0]);
    try std.testing.expectEqualStrings("c1", leftover_item.object.get("id").?.string);
    try std.testing.expectEqualStrings("{\"a\":1}", leftover_item.object.get("arguments").?.string);
}

test "inbound.responses StreamOut: 失败帧是规范形状（status/output/error 齐全）" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var out = StreamOut.init(arena, "m");
    const frames = try out.write(.{ .finish = .{ .failure = .{ .code = "SERVER", .message = "boom" } } });
    // 失败只发 response.failed 一帧（不补 response.created）。
    try std.testing.expectEqual(@as(usize, 1), frames.len);
    try std.testing.expectEqualStrings("response.failed", eventName(frames[0]));
    const payload = try eventJson(arena, frames[0]);
    try std.testing.expectEqualStrings("response.failed", payload.object.get("type").?.string);
    const response = payload.object.get("response").?.object;
    try std.testing.expectEqualStrings("response", response.get("object").?.string);
    try std.testing.expectEqualStrings("failed", response.get("status").?.string);
    try std.testing.expectEqualStrings("m", response.get("model").?.string);
    try std.testing.expect(std.mem.startsWith(u8, response.get("id").?.string, "resp_"));
    try std.testing.expectEqual(@as(usize, 0), response.get("output").?.array.items.len);
    const failure_object = response.get("error").?.object;
    try std.testing.expectEqualStrings("SERVER", failure_object.get("code").?.string);
    try std.testing.expectEqualStrings("boom", failure_object.get("message").?.string);
    try std.testing.expectEqual(@as(usize, 0), (try out.write(.{ .text_delta = .{ .index = 0, .text = "x" } })).len);
}

test "inbound.responses StreamOut: created/completed/failed 共用同一个响应 id" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var out = StreamOut.init(arena, "m");
    const frames = try out.write(.{ .text_delta = .{ .index = 0, .text = "hi" } });
    const created = try eventJson(arena, frames[0]);
    const created_id = created.object.get("response").?.object.get("id").?.string;
    const tail = try out.doneEvents();
    const completed = try eventJson(arena, tail[tail.len - 1]);
    try std.testing.expectEqualStrings("response.completed", completed.object.get("type").?.string);
    try std.testing.expectEqualStrings(created_id, completed.object.get("response").?.object.get("id").?.string);

    var failed_out = StreamOut.init(arena, "m");
    _ = try failed_out.write(.{ .text_delta = .{ .index = 0, .text = "hi" } });
    const failed_frames = try failed_out.write(.{ .finish = .{ .failure = .{ .code = "TIMEOUT", .message = "boom" } } });
    const failed = try eventJson(arena, failed_frames[0]);
    const failed_response = failed.object.get("response").?.object;
    try std.testing.expectEqualStrings("failed", failed_response.get("status").?.string);
    try std.testing.expectEqualStrings(created_id_length_check(failed_response.get("id").?.string), failed_response.get("id").?.string);
}

fn created_id_length_check(id: []const u8) []const u8 {
    std.debug.assert(std.mem.startsWith(u8, id, "resp_"));
    return id;
}

test "占位剥离：output_text 回放（responses 入站）" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var registry = try providers_mod.builtinRegistry(arena);
    defer registry.deinit();

    const placeholder = placeholder_mod.text;
    const ellipsis = placeholder_mod.ellipsis;
    const body = try std.fmt.allocPrint(arena, "{{\"model\":\"glm-5.3\",\"input\":[" ++
        "{{\"type\":\"message\",\"role\":\"user\",\"content\":\"问\"}}," ++
        "{{\"type\":\"message\",\"role\":\"assistant\",\"content\":[{{\"type\":\"output_text\",\"text\":\"{s}答，等等{s}补充\"}}]}}," ++
        "{{\"type\":\"message\",\"role\":\"user\",\"content\":\"再问\"}}]}}", .{ placeholder, ellipsis });

    const parsed = try parseObject(arena, &registry, body);
    try std.testing.expectEqual(@as(usize, 3), parsed.request.messages.len);
    try std.testing.expectEqual(types.Role.assistant, parsed.request.messages[1].role);
    try std.testing.expectEqualStrings("答，等等\u{2026}补充", parsed.request.messages[1].blocks[0].text);

    const serialized = try @import("../upstream/responses.zig").serializeBody(
        arena,
        registry.find("intern-ai").?,
        parsed.request,
    );
    try std.testing.expect(std.mem.indexOf(u8, serialized, placeholder) == null);
    try std.testing.expect(std.mem.indexOf(u8, serialized, "\u{2063}") == null);
}

test "占位帧：responses 复用已开 message item（不新增 output_index）" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var out = StreamOut.init(arena, "m");

    const placeholder = @import("../placeholder.zig").text;
    const frames = try out.writePlaceholder(placeholder);
    try std.testing.expectEqual(@as(usize, 3), frames.len); // created + item added(message) + delta
    try std.testing.expectEqualStrings("response.created", eventName(frames[0]));
    try std.testing.expectEqualStrings("response.output_item.added", eventName(frames[1]));
    const delta = try eventJson(arena, frames[2]);
    try std.testing.expectEqualStrings("response.output_text.delta", delta.object.get("type").?.string);
    try std.testing.expectEqual(@as(i64, 0), delta.object.get("output_index").?.integer);
    try std.testing.expectEqualStrings(placeholder, delta.object.get("delta").?.string);

    // 真实文本复用同一 item：只发 delta，output_index 仍为 0
    const real = try out.write(.{ .text_delta = .{ .index = 0, .text = "答" } });
    try std.testing.expectEqual(@as(usize, 1), real.len);
    const real_delta = try eventJson(arena, real[0]);
    try std.testing.expectEqual(@as(i64, 0), real_delta.object.get("output_index").?.integer);
    try std.testing.expectEqualStrings("答", real_delta.object.get("delta").?.string);
}
