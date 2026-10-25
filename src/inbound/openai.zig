//! OpenAI Chat 入站：解析 → GenerateRequest；Chunk → 响应/流式帧。
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

/// 解析 OpenAI chat 请求体（std.json.Value）→ GenerateRequest。
/// 调用方之后用 upstream.openai.resolveProvider 把 provider/model 落到剖面。
pub fn parse(
    arena: std.mem.Allocator,
    registry: *providers_mod.Registry,
    body: std.json.ObjectMap,
) !Parsed {
    const model_value = body.get("model") orelse return error.MissingModel;
    if (model_value != .string or model_value.string.len == 0) return error.MissingModel;
    const model_echo = model_value.string;

    const resolved = try @import("../upstream/openai.zig").resolveProvider(registry, model_echo);

    const raw_messages = body.get("messages") orelse return error.MissingMessages;
    if (raw_messages != .array or raw_messages.array.items.len == 0) return error.MissingMessages;

    var messages: std.ArrayList(types.Message) = .empty;
    for (raw_messages.array.items) |raw| {
        if (raw != .object) continue;
        const message = raw.object;
        const role = message.get("role") orelse continue;
        if (role != .string) continue;
        const content = message.get("content");

        if (std.mem.eql(u8, role.string, "system") or std.mem.eql(u8, role.string, "developer")) {
            const text = if (content != null and content.? == .string) content.?.string else "";
            if (text.len > 0) {
                const blocks = try arena.alloc(types.Block, 1);
                blocks[0] = .{ .text = text };
                try messages.append(arena, .{ .role = .system, .blocks = blocks });
            }
            continue;
        }
        if (std.mem.eql(u8, role.string, "user")) {
            var blocks: std.ArrayList(types.Block) = .empty;
            switch (content orelse .null) {
                .string => |text| {
                    if (text.len > 0) try blocks.append(arena, .{ .text = text });
                },
                .array => |parts| {
                    for (parts.items) |part| {
                        if (part != .object) continue;
                        const part_type = part.object.get("type") orelse continue;
                        if (part_type != .string) continue;
                        if (std.mem.eql(u8, part_type.string, "text")) {
                            if (part.object.get("text")) |text| {
                                if (text == .string and text.string.len > 0) {
                                    try blocks.append(arena, .{ .text = text.string });
                                }
                            }
                        } else if (std.mem.eql(u8, part_type.string, "image_url")) {
                            if (part.object.get("image_url")) |image_url_value| {
                                if (image_url_value == .object) {
                                    if (image_url_value.object.get("url")) |url| {
                                        if (url == .string and url.string.len > 0) {
                                            try blocks.append(arena, .{ .image = .{ .data_uri = url.string } });
                                        }
                                    }
                                }
                            }
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
            if (!meaningful) continue; // 空消息跳过
            try messages.append(arena, .{ .role = .user, .blocks = try blocks.toOwnedSlice(arena) });
            continue;
        }
        if (std.mem.eql(u8, role.string, "assistant")) {
            var blocks: std.ArrayList(types.Block) = .empty;
            if (content) |content_value| {
                if (content_value == .string and content_value.string.len > 0) {
                    try blocks.append(arena, .{ .text = content_value.string });
                }
            }
            if (message.get("tool_calls")) |tool_calls| {
                if (tool_calls == .array) {
                    for (tool_calls.array.items) |raw_call| {
                        if (raw_call != .object) continue;
                        const call = raw_call.object;
                        const call_id = call.get("id") orelse continue;
                        if (call_id != .string) continue;
                        const function = call.get("function") orelse continue;
                        if (function != .object) continue;
                        const name = function.object.get("name") orelse continue;
                        if (name != .string) continue;
                        const arguments = function.object.get("arguments") orelse std.json.Value{ .string = "{}" };
                        if (arguments != .string) continue;
                        try blocks.append(arena, .{ .tool_call = .{ .id = call_id.string, .name = name.string, .arguments = arguments.string } });
                    }
                }
            }
            if (blocks.items.len == 0) continue;
            try messages.append(arena, .{ .role = .assistant, .blocks = try blocks.toOwnedSlice(arena) });
            continue;
        }
        if (std.mem.eql(u8, role.string, "tool")) {
            const tool_call_id = message.get("tool_call_id") orelse continue;
            if (tool_call_id != .string) continue;
            var text: []const u8 = "";
            if (content) |content_value| {
                switch (content_value) {
                    .string => |value| text = value,
                    .array => |parts| {
                        var buffer: std.ArrayList(u8) = .empty;
                        for (parts.items) |part| {
                            if (part != .object) continue;
                            if (part.object.get("type")) |part_type| {
                                if (part_type == .string and std.mem.eql(u8, part_type.string, "text")) {
                                    if (part.object.get("text")) |text_value| {
                                        if (text_value == .string) {
                                            if (buffer.items.len > 0) try buffer.append(arena, '\n');
                                            try buffer.appendSlice(arena, text_value.string);
                                        }
                                    }
                                }
                            }
                        }
                        text = buffer.items;
                    },
                    else => {},
                }
            }
            const blocks = try arena.alloc(types.Block, 1);
            blocks[0] = .{ .text = text };
            try messages.append(arena, .{ .role = .tool, .blocks = blocks });
        }
    }
    if (messages.items.len == 0) return error.EmptyRequest;

    var tools: ?[]const types.ToolSchema = null;
    if (body.get("tools")) |tools_value| {
        if (tools_value == .array and tools_value.array.items.len > 0) {
            var tool_list: std.ArrayList(types.ToolSchema) = .empty;
            for (tools_value.array.items) |raw_tool| {
                if (raw_tool != .object) continue;
                const function = raw_tool.object.get("function") orelse continue;
                if (function != .object) continue;
                const name = function.object.get("name") orelse continue;
                if (name != .string) continue;
                const description: []const u8 = if (function.object.get("description")) |value| switch (value) {
                    .string => |text| text,
                    else => "",
                } else "";
                const parameters: std.json.Value = function.object.get("parameters") orelse try std.json.parseFromSliceLeaky(std.json.Value, arena, "{\"type\":\"object\",\"properties\":{}}", .{});
                try tool_list.append(arena, .{ .name = name.string, .description = description, .parameters = parameters });
            }
            if (tool_list.items.len > 0) tools = try tool_list.toOwnedSlice(arena);
        }
    }

    var reasoning_effort: ?types.Effort = null;
    if (body.get("reasoning_effort")) |value| {
        if (value == .string) reasoning_effort = effort_mod.normalizeInbound(value.string);
    } else if (body.get("reasoning")) |value| {
        if (value == .object) {
            if (value.object.get("effort")) |inner| {
                if (inner == .string) reasoning_effort = effort_mod.normalizeInbound(inner.string);
            }
        } else if (value == .string) {
            reasoning_effort = effort_mod.normalizeInbound(value.string);
        }
    }

    var max_tokens: ?u64 = null;
    if (body.get("max_completion_tokens")) |value| {
        if (value == .integer and value.integer > 0) max_tokens = @intCast(value.integer);
    }
    if (max_tokens == null) {
        if (body.get("max_tokens")) |value| {
            if (value == .integer and value.integer > 0) max_tokens = @intCast(value.integer);
        }
    }

    var stop: ?[]const []const u8 = null;
    if (body.get("stop")) |value| {
        switch (value) {
            .string => |text| {
                const list = try arena.alloc([]const u8, 1);
                list[0] = text;
                stop = list;
            },
            .array => |items| {
                var list: std.ArrayList([]const u8) = .empty;
                for (items.items) |entry| {
                    if (entry == .string) try list.append(arena, entry.string);
                }
                if (list.items.len > 0) stop = try list.toOwnedSlice(arena);
            },
            else => {},
        }
    }

    return .{
        .request = .{
            .provider = resolved.profile.name,
            .model = resolved.model,
            .messages = try placeholder_mod.stripFromMessages(arena, try messages.toOwnedSlice(arena)),
            .reasoning_effort = reasoning_effort,
            .tools = tools,
            .max_tokens = max_tokens,
            .stop = stop,
        },
        .stream = if (body.get("stream")) |value| value == .bool and value.bool else false,
        .model_echo = model_echo,
    };
}

pub fn mapFinishToWire(kind: types.FinishReason) []const u8 {
    return switch (kind) {
        .stop => "stop",
        .tool_calls => "tool_calls",
        .max_tokens => "length",
        else => "stop",
    };
}

/// 非流式组装（TS: assembleNonStream）。
pub fn assembleNonStream(arena: std.mem.Allocator, model_echo: []const u8, chunks: []const types.Chunk) ![]const u8 {
    var text: std.ArrayList(u8) = .empty;
    var reasoning: std.ArrayList(u8) = .empty;
    var tool_calls: std.ArrayList(u8) = .empty;
    var has_reasoning = false;
    var usage_json: []const u8 = "";
    var finish: []const u8 = "stop";

    for (chunks) |chunk| {
        switch (chunk) {
            .text_delta => |delta| try text.appendSlice(arena, delta.text),
            .reasoning_delta => |delta| {
                has_reasoning = true;
                try reasoning.appendSlice(arena, delta.text);
            },
            .block_end => |end| {
                if (end.block == .tool_call) {
                    const call = end.block.tool_call;
                    const entry = try std.fmt.allocPrint(arena, "{{\"id\":{f},\"type\":\"function\",\"function\":{{\"name\":{f},\"arguments\":{f}}}}}", .{
                        std.json.fmt(call.id, .{}),
                        std.json.fmt(call.name, .{}),
                        std.json.fmt(call.arguments, .{}),
                    });
                    if (tool_calls.items.len > 0) try tool_calls.append(arena, ',');
                    try tool_calls.appendSlice(arena, entry);
                }
            },
            .usage => |usage| {
                const prompt = usage.input + usage.cache_read + usage.cache_write;
                usage_json = try std.fmt.allocPrint(arena, ",\"usage\":{{\"prompt_tokens\":{d},\"completion_tokens\":{d},\"total_tokens\":{d},\"prompt_tokens_details\":{{\"cached_tokens\":{d}}},\"completion_tokens_details\":{{\"reasoning_tokens\":{d}}}}}", .{
                    prompt, usage.output, usage.total orelse prompt + usage.output, usage.cache_read, usage.reasoning,
                });
            },
            .finish => |reason| finish = mapFinishToWire(reason),
            else => {},
        }
    }

    var out: std.Io.Writer.Allocating = .init(arena);
    const w = &out.writer;
    try w.print("{{\"id\":\"gwchat-{d}-{d}\",\"object\":\"chat.completion\",\"created\":{d},\"model\":{f},\"choices\":[{{\"index\":0,\"message\":{{\"role\":\"assistant\",\"content\":", .{
        clock.unixMilli(), @rem(clock.unixMilli(), 1_000_000), clock.unixSeconds(), std.json.fmt(model_echo, .{}),
    });
    if (text.items.len > 0 or tool_calls.items.len == 0) {
        try w.print("{f}", .{std.json.fmt(text.items, .{})});
    } else {
        try w.writeAll("null");
    }
    // reasoning_content 与 tool_calls 在 message 对象内，finish_reason 在 choice 对象内
    if (has_reasoning) {
        try w.print(",\"reasoning_content\":{f}", .{std.json.fmt(reasoning.items, .{})});
    }
    if (tool_calls.items.len > 0) {
        try w.print(",\"tool_calls\":[{s}]", .{tool_calls.items});
    }
    try w.writeAll("}"); // close "message"
    try w.print(",\"finish_reason\":{f}", .{std.json.fmt(finish, .{})});
    try w.writeAll("}]"); // close choice + array
    try w.writeAll(usage_json);
    try w.writeAll("}");
    return out.written();
}

/// 流式发射器（TS: OpenAiStreamOut）。
pub const StreamOut = struct {
    arena: std.mem.Allocator,
    model_echo: []const u8,
    id: []const u8,
    tool_indexes: std.AutoHashMapUnmanaged(usize, usize) = .empty,
    finished: bool = false,
    frame_count: usize = 0,
    pending_usage: ?[]const u8 = null,

    pub fn init(arena: std.mem.Allocator, model_echo: []const u8) StreamOut {
        return .{ .arena = arena, .model_echo = model_echo, .id = "" };
    }

    fn base(self: *StreamOut, delta_json: []const u8, finish_reason: ?[]const u8) ![]const u8 {
        const finish_json = if (finish_reason) |reason| try std.fmt.allocPrint(self.arena, "{f}", .{std.json.fmt(reason, .{})}) else "null";
        return std.fmt.allocPrint(self.arena, "data: {{\"id\":\"gwchat\",\"object\":\"chat.completion.chunk\",\"created\":{d},\"model\":{f},\"choices\":[{{\"index\":0,\"delta\":{s},\"finish_reason\":{s}}}]}}\n\n", .{
            clock.unixMilli(), std.json.fmt(self.model_echo, .{}), delta_json, finish_json,
        });
    }

    /// 喂入一个 Chunk；返回要写出的完整 SSE 帧（可能 0~2 帧）。
    pub fn write(self: *StreamOut, chunk: types.Chunk) ![]const []const u8 {
        if (self.finished) return &.{};
        // arena 统管内存：不在返回前 deinit（unmanaged deinit 会置 undefined）。
        var frames: std.ArrayList([]const u8) = .empty;

        switch (chunk) {
            .text_delta => |delta| {
                const frame = try self.base(try std.fmt.allocPrint(self.arena, "{{\"content\":{f}}}", .{std.json.fmt(delta.text, .{})}), null);
                try frames.append(self.arena, frame);
            },
            .reasoning_delta => |delta| {
                const frame = try self.base(try std.fmt.allocPrint(self.arena, "{{\"reasoning_content\":{f}}}", .{std.json.fmt(delta.text, .{})}), null);
                try frames.append(self.arena, frame);
            },
            .tool_delta => |delta| {
                var seq: usize = self.tool_indexes.count();
                const existing = self.tool_indexes.get(delta.index);
                const is_new = existing == null;
                if (existing) |value| {
                    seq = value;
                } else {
                    try self.tool_indexes.put(self.arena, delta.index, seq);
                }
                var payload: std.ArrayList(u8) = .empty;
                try payload.appendSlice(self.arena, "{\"tool_calls\":[{\"index\":");
                try payload.appendSlice(self.arena, try std.fmt.allocPrint(self.arena, "{d}", .{seq}));
                if (is_new) {
                    try payload.appendSlice(self.arena, try std.fmt.allocPrint(self.arena, ",\"id\":{f},\"type\":\"function\"", .{std.json.fmt(delta.id, .{})}));
                }
                if (delta.name != null and is_new) {
                    try payload.appendSlice(self.arena, try std.fmt.allocPrint(self.arena, ",\"function\":{{\"name\":{f}", .{std.json.fmt(delta.name.?, .{})}));
                    if (delta.args_delta.len > 0) {
                        try payload.appendSlice(self.arena, try std.fmt.allocPrint(self.arena, ",\"arguments\":{f}", .{std.json.fmt(delta.args_delta, .{})}));
                    }
                    try payload.appendSlice(self.arena, "}");
                } else if (delta.args_delta.len > 0) {
                    try payload.appendSlice(self.arena, try std.fmt.allocPrint(self.arena, ",\"function\":{{\"arguments\":{f}}}", .{std.json.fmt(delta.args_delta, .{})}));
                }
                // "}" 已在上面闭合 function 对象；这里要闭合 tool_call 对象 + tool_calls 数组 +
                // 外层对象，共三个字符（此前漏了最外层 "}"，发出的帧 JSON 截断——
                // 单测接通后立刻暴露，2026-10-14 修复）。
                try payload.appendSlice(self.arena, "}]}");
                const frame = try self.base(payload.items, null);
                try frames.append(self.arena, frame);
            },
            .usage => |usage| {
                const prompt = usage.input + usage.cache_read + usage.cache_write;
                self.pending_usage = try std.fmt.allocPrint(self.arena, "data: {{\"id\":\"gwchat\",\"object\":\"chat.completion.chunk\",\"created\":{d},\"model\":{f},\"choices\":[],\"usage\":{{\"prompt_tokens\":{d},\"completion_tokens\":{d},\"total_tokens\":{d}}}}}\n\n", .{
                    clock.unixMilli(), std.json.fmt(self.model_echo, .{}), prompt, usage.output, usage.total orelse prompt + usage.output,
                });
                return &.{};
            },
            .finish => |reason| {
                switch (reason) {
                    .failure => |failure| {
                        self.finished = true;
                        const frame = try std.fmt.allocPrint(self.arena, "data: {{\"error\":{{\"message\":{f},\"type\":\"gateway_error\",\"code\":{f}}}}}\n\ndata: [DONE]\n\n", .{
                            std.json.fmt(failure.message, .{}), std.json.fmt(failure.code, .{}),
                        });
                        try frames.append(self.arena, frame);
                        return frames.items;
                    },
                    else => {},
                }
                const finish_name = mapFinishToWire(reason);
                const frame = try self.base("{}", finish_name);
                try frames.append(self.arena, frame);
                if (self.pending_usage) |usage_frame| {
                    try frames.append(self.arena, usage_frame);
                    self.pending_usage = null;
                }
                self.finished = true;
            },
            else => return &.{},
        }
        if (frames.items.len > 0 and self.frame_count == 0) {
            const role_frame = try self.base("{\"role\":\"assistant\",\"content\":\"\"}", null);
            try frames.insert(self.arena, 0, role_frame);
        }
        self.frame_count += frames.items.len;
        return frames.items;
    }

    /// 占位保活（静默时由看门狗调用）：openai 的文本增量不看 index，
    /// 直接追加一个 content 增量即可——同一个 message 里与真实回答自然拼接，零块切换。
    pub fn writePlaceholder(self: *StreamOut, placeholder_text: []const u8) ![]const []const u8 {
        return self.write(.{ .text_delta = .{ .index = 0, .text = placeholder_text } });
    }

    /// 中途失败帧（TS: OpenAiStreamOut.errorFrames）。
    pub fn errorFrames(arena: std.mem.Allocator, message: []const u8, code: []const u8) ![]const []const u8 {
        const error_frame = try std.fmt.allocPrint(arena, "data: {{\"error\":{{\"message\":{f},\"type\":\"gateway_error\",\"code\":{f}}}}}\n\n", .{ std.json.fmt(message, .{}), std.json.fmt(code, .{}) });
        const frames = try arena.alloc([]const u8, 2);
        frames[0] = error_frame;
        frames[1] = "data: [DONE]\n\n";
        return frames;
    }

    pub fn doneFrames(self: *StreamOut) ![]const []const u8 {
        self.finished = true;
        if (self.pending_usage) |usage_frame| {
            self.pending_usage = null;
            const frames = try self.arena.alloc([]const u8, 2);
            frames[0] = usage_frame;
            frames[1] = "data: [DONE]\n\n";
            return frames;
        }
        const frames = try self.arena.alloc([]const u8, 1);
        frames[0] = "data: [DONE]\n\n";
        return frames;
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

fn frameJson(arena: std.mem.Allocator, frame: []const u8) !std.json.Value {
    std.debug.assert(std.mem.startsWith(u8, frame, "data: "));
    const payload = std.mem.trimEnd(u8, frame["data: ".len..], "\n");
    return std.json.parseFromSliceLeaky(std.json.Value, arena, payload, .{});
}

test "inbound.openai parse: 错误集" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var registry = try providers_mod.builtinRegistry(arena);
    defer registry.deinit();

    try std.testing.expectError(error.MissingModel, parseObject(arena, &registry, "{\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]}"));
    try std.testing.expectError(error.MissingModel, parseObject(arena, &registry, "{\"model\":\"\",\"messages\":[]}"));
    try std.testing.expectError(error.MissingMessages, parseObject(arena, &registry, "{\"model\":\"glm-5.3\"}"));
    // 全是空 user 消息 → EmptyRequest
    try std.testing.expectError(error.EmptyRequest, parseObject(arena, &registry, "{\"model\":\"glm-5.3\",\"messages\":[{\"role\":\"user\",\"content\":\"\"}]}"));
    try std.testing.expectError(error.UnknownModel, parseObject(arena, &registry, "{\"model\":\"nope/nope\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]}"));
}

test "inbound.openai parse: 消息投影与字段回放" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var registry = try providers_mod.builtinRegistry(arena);
    defer registry.deinit();

    const body =
        \\{"model":"intern-ai/glm-5.3","stream":true,
        \\ "messages":[
        \\   {"role":"system","content":"S1"},
        \\   {"role":"developer","content":"D1"},
        \\   {"role":"user","content":[{"type":"text","text":"看图"},{"type":"image_url","image_url":{"url":"data:image/png;base64,AQID"}}]},
        \\   {"role":"assistant","content":"","tool_calls":[{"id":"call_1","type":"function","function":{"name":"get_weather","arguments":"{\"city\":\"SF\"}"}}]},
        \\   {"role":"tool","tool_call_id":"call_1","content":"sunny"}],
        \\ "reasoning_effort":"ultra",
        \\ "max_completion_tokens":123,
        \\ "max_tokens":999,
        \\ "stop":"END",
        \\ "tools":[{"type":"function","function":{"name":"get_weather","description":"weather"}}]}
    ;
    const parsed = try parseObject(arena, &registry, body);
    try std.testing.expect(parsed.stream);
    try std.testing.expectEqualStrings("intern-ai", parsed.request.provider);
    try std.testing.expectEqualStrings("glm-5.3", parsed.request.model);
    try std.testing.expectEqual(types.Effort.max, parsed.request.reasoning_effort.?); // ultra→max
    try std.testing.expectEqual(@as(u64, 123), parsed.request.max_tokens.?); // max_completion_tokens 优先
    try std.testing.expectEqualStrings("END", parsed.request.stop.?[0]);
    try std.testing.expectEqualStrings("get_weather", parsed.request.tools.?[0].name);
    // tools 无 parameters → 默认空对象 schema
    try std.testing.expectEqualStrings("object", parsed.request.tools.?[0].parameters.object.get("type").?.string);

    const messages = parsed.request.messages;
    try std.testing.expectEqual(@as(usize, 5), messages.len);
    try std.testing.expectEqual(types.Role.system, messages[0].role); // system
    try std.testing.expectEqualStrings("S1", messages[0].blocks[0].text);
    try std.testing.expectEqual(types.Role.system, messages[1].role); // developer→system
    try std.testing.expectEqual(types.Role.user, messages[2].role);
    try std.testing.expectEqualStrings("看图", messages[2].blocks[0].text);
    try std.testing.expectEqualStrings("data:image/png;base64,AQID", messages[2].blocks[1].image.data_uri);
    try std.testing.expectEqual(types.Role.assistant, messages[3].role);
    try std.testing.expectEqualStrings("get_weather", messages[3].blocks[0].tool_call.name);
    try std.testing.expectEqual(types.Role.tool, messages[4].role);
    try std.testing.expectEqualStrings("sunny", messages[4].blocks[0].text);
}

test "inbound.openai parse: 空 user 跳过 / reasoning 对象形态 / stop 数组" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var registry = try providers_mod.builtinRegistry(arena);
    defer registry.deinit();

    const body =
        \\{"model":"glm-5.3","messages":[
        \\  {"role":"user","content":""},
        \\  {"role":"user","content":"real"}],
        \\ "reasoning":{"effort":"disabled"},
        \\ "stop":["A","B"]}
    ;
    const parsed = try parseObject(arena, &registry, body);
    try std.testing.expectEqual(types.Effort.off, parsed.request.reasoning_effort.?); // disabled→off
    try std.testing.expectEqual(@as(usize, 1), parsed.request.messages.len); // 空 user 被跳过
    try std.testing.expectEqual(@as(usize, 2), parsed.request.stop.?.len);
}

test "inbound.openai assembleNonStream: 文本+推理+usage" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const chunks = [_]types.Chunk{
        .{ .text_delta = .{ .index = 0, .text = "答" } },
        .{ .reasoning_delta = .{ .index = 1, .text = "想" } },
        .{ .usage = .{ .input = 10, .output = 5, .total = 17, .cache_read = 2, .cache_write = 1, .reasoning = 3 } },
        .{ .finish = .stop },
    };
    const body = try assembleNonStream(arena, "intern-ai/glm-5.3", &chunks);
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{});
    const message = parsed.object.get("choices").?.array.items[0].object.get("message").?.object;
    try std.testing.expectEqualStrings("答", message.get("content").?.string);
    try std.testing.expectEqualStrings("想", message.get("reasoning_content").?.string);
    const choice = parsed.object.get("choices").?.array.items[0].object;
    try std.testing.expectEqualStrings("stop", choice.get("finish_reason").?.string);
    const usage = parsed.object.get("usage").?.object;
    try std.testing.expectEqual(@as(i64, 13), usage.get("prompt_tokens").?.integer); // input+cache_read+cache_write
    try std.testing.expectEqual(@as(i64, 17), usage.get("total_tokens").?.integer);
    try std.testing.expectEqual(@as(i64, 3), usage.get("completion_tokens_details").?.object.get("reasoning_tokens").?.integer);
}

test "inbound.openai assembleNonStream: 仅工具调用 → content=null" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const chunks = [_]types.Chunk{
        .{ .block_end = .{ .index = 0, .block = .{ .tool_call = .{ .id = "call_1", .name = "get_weather", .arguments = "{\"city\":\"SF\"}" } } } },
        .{ .finish = .tool_calls },
    };
    const body = try assembleNonStream(arena, "m", &chunks);
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{});
    const message = parsed.object.get("choices").?.array.items[0].object.get("message").?.object;
    try std.testing.expect(message.get("content").? == .null);
    const call = message.get("tool_calls").?.array.items[0].object;
    try std.testing.expectEqualStrings("call_1", call.get("id").?.string);
    try std.testing.expectEqualStrings("get_weather", call.get("function").?.object.get("name").?.string);
    try std.testing.expectEqualStrings("tool_calls", parsed.object.get("choices").?.array.items[0].object.get("finish_reason").?.string);
}

test "inbound.openai StreamOut: 首帧 role、工具 seq 映射、usage 延迟、[DONE]" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var out = StreamOut.init(arena, "m");

    // 首帧前插入 role 帧
    const frames = try out.write(.{ .text_delta = .{ .index = 0, .text = "hi" } });
    try std.testing.expectEqual(@as(usize, 2), frames.len);
    const role = try frameJson(arena, frames[0]);
    const role_delta = role.object.get("choices").?.array.items[0].object.get("delta").?.object;
    try std.testing.expectEqualStrings("assistant", role_delta.get("role").?.string);
    const text = try frameJson(arena, frames[1]);
    try std.testing.expectEqualStrings("hi", text.object.get("choices").?.array.items[0].object.get("delta").?.object.get("content").?.string);

    // 工具：同一 IR index 两次 → seq 相同，第二次不带 id
    const tool_frames = try out.write(.{ .tool_delta = .{ .index = 5, .id = "call_1", .name = "fn", .args_delta = "{}" } });
    const tool = try frameJson(arena, tool_frames[0]);
    const call = tool.object.get("choices").?.array.items[0].object.get("delta").?.object.get("tool_calls").?.array.items[0].object;
    try std.testing.expectEqual(@as(i64, 0), call.get("index").?.integer);
    try std.testing.expectEqualStrings("call_1", call.get("id").?.string);
    const again = try out.write(.{ .tool_delta = .{ .index = 5, .id = "call_1", .name = null, .args_delta = "x" } });
    const again_call = (try frameJson(arena, again[0])).object.get("choices").?.array.items[0].object.get("delta").?.object.get("tool_calls").?.array.items[0].object;
    try std.testing.expect(again_call.get("id") == null);

    // usage 暂存：write 返回空，doneFrames 带 usage + [DONE]
    const no_frames = try out.write(.{ .usage = .{ .input = 1, .output = 2, .total = 3, .cache_read = 0, .cache_write = 0, .reasoning = 0 } });
    try std.testing.expectEqual(@as(usize, 0), no_frames.len);
    const done = try out.doneFrames();
    try std.testing.expectEqual(@as(usize, 2), done.len);
    try std.testing.expectEqualStrings("data: [DONE]\n\n", done[1]);
    const usage_frame = try frameJson(arena, done[0]);
    try std.testing.expectEqualStrings("chat.completion.chunk", usage_frame.object.get("object").?.string);
    try std.testing.expect(out.finished);
}

test "inbound.openai StreamOut: finish 名称与失败帧" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var ok = StreamOut.init(arena, "m");
    const frames = try ok.write(.{ .finish = .max_tokens });
    const finish = try frameJson(arena, frames[frames.len - 1]);
    try std.testing.expectEqualStrings("length", finish.object.get("choices").?.array.items[0].object.get("finish_reason").?.string);

    var failed = StreamOut.init(arena, "m");
    const failure_frames = try failed.write(.{ .finish = .{ .failure = .{ .code = "SERVER", .message = "boom" } } });
    try std.testing.expectEqual(@as(usize, 1), failure_frames.len);
    try std.testing.expect(std.mem.indexOf(u8, failure_frames[0], "[DONE]") != null);
    try std.testing.expect(std.mem.indexOf(u8, failure_frames[0], "\"code\":\"SERVER\"") != null);
    // 失败后 finished：后续 write 为空
    try std.testing.expectEqual(@as(usize, 0), (try failed.write(.{ .text_delta = .{ .index = 0, .text = "x" } })).len);
}

test "占位剥离：回灌历史无哨兵、消息数/序不变、裸省略号保留（openai 入站）" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var registry = try providers_mod.builtinRegistry(arena);
    defer registry.deinit();

    const placeholder = placeholder_mod.text;
    const ellipsis = placeholder_mod.ellipsis;
    // 上游在 assistant 文本里掺了占位（回灌形态）；末尾的正常省略号必须原样保留
    const tainted = try std.fmt.allocPrint(arena, "{{\"model\":\"glm-5.3\",\"messages\":[" ++
        "{{\"role\":\"user\",\"content\":\"你好\"}}," ++
        "{{\"role\":\"assistant\",\"content\":\"{s}答，等等{s}补充\"}}," ++
        "{{\"role\":\"user\",\"content\":\"继续\"}}]}}", .{ placeholder, ellipsis });
    const control = try std.fmt.allocPrint(arena, "{{\"model\":\"glm-5.3\",\"messages\":[" ++
        "{{\"role\":\"user\",\"content\":\"你好\"}}," ++
        "{{\"role\":\"assistant\",\"content\":\"答，等等{s}补充\"}}," ++
        "{{\"role\":\"user\",\"content\":\"继续\"}}]}}", .{ellipsis});

    const parsed_tainted = try parseObject(arena, &registry, tainted);
    const parsed_control = try parseObject(arena, &registry, control);

    // 结构不变式：消息数/角色/块数一致
    try std.testing.expectEqual(parsed_control.request.messages.len, parsed_tainted.request.messages.len);
    for (parsed_control.request.messages, parsed_tainted.request.messages) |a, b| {
        try std.testing.expectEqual(a.role, b.role);
        try std.testing.expectEqual(a.blocks.len, b.blocks.len);
    }
    // 内容：与对照逐字一致（哨兵被删、裸省略号保留）
    try std.testing.expectEqualStrings(
        parsed_control.request.messages[1].blocks[0].text,
        parsed_tainted.request.messages[1].blocks[0].text,
    );
    try std.testing.expectEqualStrings("答，等等\u{2026}补充", parsed_tainted.request.messages[1].blocks[0].text);

    // 上游序列化体无哨兵（防 token 浪费的最终断言）
    const serialized = try @import("../upstream/openai.zig").serializeMessages(
        arena,
        registry.find("intern-ai").?,
        "glm-5.3",
        parsed_tainted.request,
    );
    try std.testing.expect(std.mem.indexOf(u8, serialized, placeholder) == null);
    try std.testing.expect(std.mem.indexOf(u8, serialized, "\u{2063}") == null);
}

test "占位帧：openai 在同一 message 内容里拼接（role 帧仍在首、零块切换）" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var out = StreamOut.init(arena, "m");

    const placeholder = @import("../placeholder.zig").text;
    const frames = try out.writePlaceholder(placeholder);
    try std.testing.expectEqual(@as(usize, 2), frames.len); // role + content
    const role = try frameJson(arena, frames[0]);
    try std.testing.expectEqualStrings("assistant", role.object.get("choices").?.array.items[0].object.get("delta").?.object.get("role").?.string);
    const placeholder_frame = try frameJson(arena, frames[1]);
    try std.testing.expectEqualStrings(placeholder, placeholder_frame.object.get("choices").?.array.items[0].object.get("delta").?.object.get("content").?.string);

    // 真实回答紧随其后：同一 message 内容增量，无新 role 帧
    const real = try out.write(.{ .text_delta = .{ .index = 0, .text = "答" } });
    try std.testing.expectEqual(@as(usize, 1), real.len);
    const real_frame = try frameJson(arena, real[0]);
    try std.testing.expectEqualStrings("答", real_frame.object.get("choices").?.array.items[0].object.get("delta").?.object.get("content").?.string);
    // 客户端拼接结果 = 占位 + 真实回答
    try std.testing.expectEqualStrings(placeholder, placeholder_frame.object.get("choices").?.array.items[0].object.get("delta").?.object.get("content").?.string);
}
