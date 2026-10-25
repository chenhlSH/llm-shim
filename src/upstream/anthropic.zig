//! Anthropic Messages 上游适配器：dsh IR → /v1/messages wire，SSE → Chunk。
//! 屏蔽规则：thinking 按策略透传（未知厂商恒省略）、reasoning 历史丢弃、
//! tool_result 合并进 user 消息、空结果 (no output)、图片转 base64 source。
const std = @import("std");
const types = @import("../types.zig");
const effort_mod = @import("../effort.zig");
const http_util = @import("../http_util.zig");
const watchdog_mod = @import("../watchdog.zig");
const client_key = @import("../client_key.zig");
const version_mod = @import("../version.zig");
const providers_mod = @import("../providers.zig");
const env = @import("../env.zig");
const openai = @import("openai.zig");

pub const Failure = openai.Failure;
pub const Client = openai.Client;

const placeholder = "[图片已省略：当前模型不支持视觉输入]";

/// 消息投影：IR → Anthropic messages JSON 数组文本。
fn serializeMessages(
    arena: std.mem.Allocator,
    profile: *const providers_mod.Profile,
    model: []const u8,
    request: types.GenerateRequest,
) ![]const u8 {
    const vision = blk: {
        for (profile.models) |candidate| {
            if (std.mem.eql(u8, candidate.id, model)) break :blk candidate.vision;
        }
        break :blk false;
    };
    var out: std.Io.Writer.Allocating = .init(arena);
    const w = &out.writer;
    try w.writeAll("[");

    var first = true;
    var pending_results: std.ArrayList(u8) = .empty;
    var pending_count: usize = 0;

    for (request.messages) |message| {
        switch (message.role) {
            .system => {}, // 已由 system 顶层字段承载
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
                            if (parts.items.len > 0) try parts.append(arena, ',');
                            try parts.appendSlice(arena, part);
                        },
                        .image => |image| {
                            has_image = true;
                            if (vision) {
                                // data URI → base64 source
                                const data = imageData(image.data_uri);
                                const part = try std.fmt.allocPrint(arena, "{{\"type\":\"image\",\"source\":{{\"type\":\"base64\",\"media_type\":{f},\"data\":{f}}}}}", .{
                                    std.json.fmt(data.media_type, .{}), std.json.fmt(data.bytes, .{}),
                                });
                                if (parts.items.len > 0) try parts.append(arena, ',');
                                try parts.appendSlice(arena, part);
                            } else {
                                const part = try std.fmt.allocPrint(arena, "{{\"type\":\"text\",\"text\":{f}}}", .{std.json.fmt(placeholder, .{})});
                                if (parts.items.len > 0) try parts.append(arena, ',');
                                try parts.appendSlice(arena, part);
                            }
                        },
                        .reasoning, .tool_call => {},
                    }
                }
                // tool_result 消息与 user 消息合并（TS 行为）
                if (pending_count > 0) {
                    if (parts.items.len > 0) try parts.append(arena, ',');
                    try parts.appendSlice(arena, pending_results.items);
                    pending_results.clearRetainingCapacity();
                    pending_count = 0;
                }
                const meaningful = blk: {
                    for (message.blocks) |block| {
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
                if (!meaningful and pending_results.items.len == 0) continue;
                if (!first) try w.writeAll(",");
                first = false;
                try w.writeAll("{\"role\":\"user\",\"content\":[");
                try w.writeAll(parts.items);
                try w.writeAll("]}");
            },
            .assistant => {
                if (pending_count > 0) {
                    if (!first) try w.writeAll(",");
                    first = false;
                    try w.writeAll("{\"role\":\"user\",\"content\":[");
                    try w.writeAll(pending_results.items);
                    try w.writeAll("]}");
                    pending_results.clearRetainingCapacity();
                    pending_count = 0;
                }
                var parts: std.ArrayList(u8) = .empty;
                for (message.blocks) |block| {
                    switch (block) {
                        .text => |text| {
                            if (text.len == 0) continue;
                            const part = try std.fmt.allocPrint(arena, "{{\"type\":\"text\",\"text\":{f}}}", .{std.json.fmt(text, .{})});
                            if (parts.items.len > 0) try parts.append(arena, ',');
                            try parts.appendSlice(arena, part);
                        },
                        .tool_call => |call| {
                            const part = try std.fmt.allocPrint(arena, "{{\"type\":\"tool_use\",\"id\":{f},\"name\":{f},\"input\":{s}}}", .{
                                std.json.fmt(call.id, .{}), std.json.fmt(call.name, .{}), jsonOrEmptyObject(call.arguments),
                            });
                            if (parts.items.len > 0) try parts.append(arena, ',');
                            try parts.appendSlice(arena, part);
                        },
                        .reasoning, .image => {},
                    }
                }
                if (parts.items.len == 0) continue;
                if (!first) try w.writeAll(",");
                first = false;
                try w.writeAll("{\"role\":\"assistant\",\"content\":[");
                try w.writeAll(parts.items);
                try w.writeAll("]}");
            },
            .tool => {
                var text: []const u8 = "";
                for (message.blocks) |block| {
                    if (block == .text) {
                        text = block.text;
                        break;
                    }
                }
                const body_text = if (text.len > 0) text else "(no output)";
                const part = try std.fmt.allocPrint(arena, "{{\"type\":\"tool_result\",\"tool_use_id\":{f},\"content\":[{{\"type\":\"text\",\"text\":{f}}}]}}", .{
                    std.json.fmt(toolIdOf(message), .{}), std.json.fmt(body_text, .{}),
                });
                if (pending_results.items.len > 0) try pending_results.append(arena, ',');
                try pending_results.appendSlice(arena, part);
                pending_count += 1;
            },
        }
    }
    if (pending_count > 0) {
        if (!first) try w.writeAll(",");
        try w.writeAll("{\"role\":\"user\",\"content\":[");
        try w.writeAll(pending_results.items);
        try w.writeAll("]}");
    }
    try w.writeAll("]");
    return out.written();
}

/// tool 消息的 call id 存放在 text 块前的隐藏约定：用 tool_call_id 字段。
/// Zig IR 里 tool 消息没有独立 id 字段——从 message.blocks 的 tool_call 关联取。
fn toolIdOf(message: types.Message) []const u8 {
    for (message.blocks) |block| {
        if (block == .tool_call) return block.tool_call.id;
    }
    return "";
}

fn jsonOrEmptyObject(raw: []const u8) []const u8 {
    _ = std.json.parseFromSliceLeaky(std.json.Value, std.heap.page_allocator, raw, .{}) catch return "{}";
    return raw;
}

fn imageData(data_uri: []const u8) struct { media_type: []const u8, bytes: []const u8 } {
    const semi = std.mem.indexOfScalar(u8, data_uri, ';') orelse return .{ .media_type = "image/png", .bytes = "" };
    const marker = std.mem.indexOf(u8, data_uri, "base64,") orelse return .{ .media_type = "image/png", .bytes = "" };
    return .{ .media_type = data_uri["data:".len..semi], .bytes = data_uri[marker + "base64,".len ..] };
}

/// 请求体序列化。
pub fn serializeBody(
    arena: std.mem.Allocator,
    profile: *const providers_mod.Profile,
    request: types.GenerateRequest,
) ![]const u8 {
    const model = request.model;
    var out: std.Io.Writer.Allocating = .init(arena);
    const w = &out.writer;
    try w.print("{{\"model\":{f},\"max_tokens\":{d},\"messages\":", .{
        std.json.fmt(model, .{}),
        request.max_tokens orelse profile.default_max_tokens,
    });
    try w.writeAll(try serializeMessages(arena, profile, model, request));
    try w.writeAll(",\"stream\":true");

    if (request.system) |system| {
        if (system.len > 0) try w.print(",\"system\":{f}", .{std.json.fmt(system, .{})});
    }
    // thinking 映射（unknown → 恒省略，防 400）
    if (request.reasoning_effort) |effort| {
        switch (profile.thinking_strategy) {
            .omit => {},
            .generic_budgets => {
                if (effort_mod.anthropicBudget(effort)) |budget| {
                    try w.print(",\"thinking\":{{\"type\":\"enabled\",\"budget_tokens\":{d}}}", .{budget});
                }
            },
        }
    }
    if (request.tools) |tools| {
        if (tools.len > 0) {
            try w.writeAll(",\"tools\":[");
            for (tools, 0..) |tool, index| {
                if (index > 0) try w.writeAll(",");
                try w.print("{{\"name\":{f},\"description\":{f},\"input_schema\":{f}}}", .{
                    std.json.fmt(tool.name, .{}), std.json.fmt(tool.description, .{}), std.json.fmt(tool.parameters, .{}),
                });
            }
            try w.writeAll("]");
        }
    }
    if (request.temperature) |temperature| {
        try w.print(",\"temperature\":{d}", .{temperature});
    }
    if (request.stop) |stop| {
        if (stop.len > 0) {
            try w.writeAll(",\"stop_sequences\":");
            try std.json.Stringify.value(stop, .{}, w);
        }
    }
    try w.writeAll("}");
    return out.written();
}

// ---------------------------------------------------------------------------
// SSE → Chunk 翻译（TS: AnthropicStreamTranslator）
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
    next_index: usize = 0,
    open: std.ArrayList(*OpenBlock) = .empty,
    input_tokens: u64 = 0,
    output_tokens: u64 = 0,
    pending_finish: ?types.FinishReason = null,
    finished: bool = false,
    response_id: ?[]const u8 = null,
    chunks: std.ArrayList(types.Chunk) = .empty,

    pub fn init(arena: std.mem.Allocator, pkg: []const u8) Translator {
        return .{ .arena = arena, .pkg = pkg };
    }

    pub fn deinit(self: *Translator) void {
        // arena 统管：不逐块 deinit（0.17 deinit 会把缓冲置 undefined，
        // 而 block_end chunk 仍引用这些切片——请求 arena 释放全部）。
        self.open.deinit(self.arena);
        self.chunks.deinit(self.arena);
    }

    pub fn translate(self: *Translator, data: []const u8) ![]const types.Chunk {
        self.chunks.clearRetainingCapacity();
        if (std.mem.eql(u8, data, "[DONE]")) return self.chunks.items;
        const parsed = std.json.parseFromSliceLeaky(std.json.Value, self.arena, data, .{}) catch {
            try self.chunks.append(self.arena, try openai.failureChunk(self.arena, self.pkg, "malformed SSE JSON frame", "MALFORMED_RESPONSE"));
            return self.chunks.items;
        };
        if (parsed != .object) return self.chunks.items;
        const root = parsed.object;
        const event_type = if (root.get("type")) |value| (if (value == .string) value.string else "") else "";

        if (std.mem.eql(u8, event_type, "message_start")) {
            if (root.get("message")) |message| {
                if (message == .object) {
                    if (message.object.get("id")) |id| {
                        if (id == .string) self.response_id = id.string;
                    }
                    if (message.object.get("usage")) |usage| {
                        if (usage == .object) {
                            if (openai.jsonInt(usage.object, "input_tokens")) |tokens| self.input_tokens = tokens;
                        }
                    }
                }
            }
        } else if (std.mem.eql(u8, event_type, "content_block_start")) {
            const block_value = root.get("content_block");
            const block_type = if (block_value != null and block_value.? == .object)
                (if (block_value.?.object.get("type")) |t| (if (t == .string) t.string else "text") else "text")
            else
                "text";
            const kind: types.BlockKind = if (std.mem.eql(u8, block_type, "thinking")) .reasoning else if (std.mem.eql(u8, block_type, "tool_use")) .tool_call else .text;
            const block = try self.arena.create(OpenBlock);
            var tool_id: []const u8 = "";
            var tool_name: std.ArrayList(u8) = .empty;
            if (block_value != null and block_value.? == .object) {
                if (block_value.?.object.get("id")) |id| {
                    if (id == .string) tool_id = id.string;
                }
                if (block_value.?.object.get("name")) |name| {
                    if (name == .string) try tool_name.appendSlice(self.arena, name.string);
                }
            }
            block.* = .{ .kind = kind, .index = self.next_index, .text = .empty, .tool_id = tool_id, .tool_name = tool_name };
            self.next_index += 1;
            try self.open.append(self.arena, block);
        } else if (std.mem.eql(u8, event_type, "content_block_delta")) {
            const block = if (self.open.items.len > 0) self.open.items[self.open.items.len - 1] else null;
            if (block) |b| {
                const delta = root.get("delta");
                if (delta != null and delta.? == .object) {
                    const delta_type = if (delta.?.object.get("type")) |t| (if (t == .string) t.string else "") else "";
                    if (std.mem.eql(u8, delta_type, "text_delta")) {
                        const text = if (delta.?.object.get("text")) |t| (if (t == .string) t.string else "") else "";
                        if (text.len > 0) {
                            try b.text.appendSlice(self.arena, text);
                            try self.chunks.append(self.arena, .{ .text_delta = .{ .index = b.index, .text = text } });
                        }
                    } else if (std.mem.eql(u8, delta_type, "thinking_delta")) {
                        const text = if (delta.?.object.get("thinking")) |t| (if (t == .string) t.string else "") else "";
                        if (text.len > 0) {
                            try b.text.appendSlice(self.arena, text);
                            try self.chunks.append(self.arena, .{ .reasoning_delta = .{ .index = b.index, .text = text } });
                        }
                    } else if (std.mem.eql(u8, delta_type, "input_json_delta")) {
                        const partial = if (delta.?.object.get("partial_json")) |t| (if (t == .string) t.string else "") else "";
                        if (partial.len > 0 and b.kind == .tool_call) {
                            try b.text.appendSlice(self.arena, partial);
                            try self.chunks.append(self.arena, .{ .tool_delta = .{ .index = b.index, .id = b.tool_id, .name = null, .args_delta = partial } });
                        }
                    }
                }
            }
        } else if (std.mem.eql(u8, event_type, "content_block_stop")) {
            const block = if (self.open.items.len > 0) self.open.pop() else null;
            if (block) |b| {
                try self.chunks.append(self.arena, try self.closeBlock(b));
            }
        } else if (std.mem.eql(u8, event_type, "message_delta")) {
            if (root.get("usage")) |usage| {
                if (usage == .object) {
                    if (openai.jsonInt(usage.object, "output_tokens")) |tokens| self.output_tokens = tokens;
                }
            }
            if (root.get("delta")) |delta| {
                if (delta == .object) {
                    const stop_reason = if (delta.object.get("stop_reason")) |t| (if (t == .string) t.string else "") else "";
                    if (stop_reason.len > 0) self.pending_finish = mapStop(stop_reason);
                }
            }
        } else if (std.mem.eql(u8, event_type, "error")) {
            const message = blk: {
                if (root.get("error")) |error_value| {
                    if (error_value == .object) {
                        if (error_value.object.get("message")) |m| {
                            if (m == .string) break :blk m.string;
                        }
                    }
                }
                break :blk "provider error event";
            };
            try self.chunks.append(self.arena, try openai.failureChunk(self.arena, self.pkg, message, "SERVER"));
        }
        return self.chunks.items;
    }

    fn closeBlock(self: *Translator, block: *OpenBlock) !types.Chunk {
        _ = self;
        switch (block.kind) {
            .text => return .{ .block_end = .{ .index = block.index, .block = .{ .text = block.text.items } } },
            .reasoning => return .{ .block_end = .{ .index = block.index, .block = .{ .reasoning = block.text.items } } },
            .tool_call => return .{ .block_end = .{ .index = block.index, .block = .{ .tool_call = .{ .id = block.tool_id, .name = block.tool_name.items, .arguments = block.text.items } } } },
        }
    }

    /// 流结束后收尾：无条件 usage + finish（与 OpenAI 不同，无 finish 不算错）。
    pub fn finalize(self: *Translator) ![]const types.Chunk {
        self.chunks.clearRetainingCapacity();
        if (self.finished) return self.chunks.items;
        for (self.open.items) |block| {
            try self.chunks.append(self.arena, try self.closeBlock(block));
        }
        try self.chunks.append(self.arena, .{ .usage = .{ .input = self.input_tokens, .output = self.output_tokens, .total = self.input_tokens + self.output_tokens } });
        try self.chunks.append(self.arena, .{ .finish = self.pending_finish orelse .stop });
        self.finished = true;
        return self.chunks.items;
    }
};

fn mapStop(raw: []const u8) types.FinishReason {
    if (std.mem.eql(u8, raw, "tool_use")) return .tool_calls;
    if (std.mem.eql(u8, raw, "max_tokens")) return .max_tokens;
    return .stop;
}

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------

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
        .protocol = .anthropic,
        .models = &test_models,
        .default_max_tokens = 555,
    };
}

fn expectContains(haystack: []const u8, needle: []const u8) !void {
    try std.testing.expect(std.mem.indexOf(u8, haystack, needle) != null);
}

test "upstream.anthropic serializeBody: max_tokens 默认 / thinking 策略 / stop" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const base = testProfile();
    var request = types.GenerateRequest{
        .provider = "p",
        .model = "text-model",
        .messages = &.{},
        .reasoning_effort = .high,
        .stop = &.{"END"},
    };

    const body = try serializeBody(arena, &base, request);
    try expectContains(body, "\"max_tokens\":555"); // request 未给 → profile 默认
    try expectContains(body, "\"stop_sequences\":[\"END\"]");
    try expectContains(body, "\"stream\":true");
    try std.testing.expect(std.mem.indexOf(u8, body, "thinking") == null); // 默认 .omit 恒省略

    var budgets = base;
    budgets.thinking_strategy = .generic_budgets;
    const body2 = try serializeBody(arena, &budgets, request);
    try expectContains(body2, "\"thinking\":{\"type\":\"enabled\",\"budget_tokens\":16384}"); // high

    request.reasoning_effort = .off; // off 必须省略
    const body3 = try serializeBody(arena, &budgets, request);
    try std.testing.expect(std.mem.indexOf(u8, body3, "thinking") == null);

    request.reasoning_effort = .high;
    request.max_tokens = 42;
    const body4 = try serializeBody(arena, &base, request);
    try expectContains(body4, "\"max_tokens\":42");
}

test "upstream.anthropic serializeMessages: tool_result 合并/图片 base64/占位" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const profile = testProfile();

    const messages = [_]types.Message{
        .{ .role = .user, .blocks = &.{ .{ .text = "看图" }, .{ .image = .{ .data_uri = "data:image/png;base64,AQID" } } } },
        .{ .role = .assistant, .blocks = &.{.{ .tool_call = .{ .id = "c1", .name = "fn", .arguments = "{\"a\":1}" } }} },
        .{ .role = .tool, .blocks = &.{ .{ .tool_call = .{ .id = "c1", .name = "", .arguments = "{}" } }, .{ .text = "" } } },
        .{ .role = .user, .blocks = &.{.{ .text = "继续" }} },
    };
    const request = types.GenerateRequest{ .provider = "p", .model = "vision-model", .messages = &messages };

    const body = try serializeMessages(arena, &profile, "vision-model", request);
    try expectContains(body, "\"source\":{\"type\":\"base64\",\"media_type\":\"image/png\",\"data\":\"AQID\"}");
    try expectContains(body, "\"type\":\"tool_use\",\"id\":\"c1\",\"name\":\"fn\",\"input\":{\"a\":1}");
    try expectContains(body, "\"type\":\"tool_result\",\"tool_use_id\":\"c1\"");
    try expectContains(body, "(no output)"); // 空工具结果占位
    // tool_result 与后续 user 合并 → 只出现两条 user 消息
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, body, "\"role\":\"user\""));

    const plain = try serializeMessages(arena, &profile, "text-model", request);
    try expectContains(plain, "[图片已省略"); // 非视觉模型 → 占位文本
    try std.testing.expect(std.mem.indexOf(u8, plain, "base64") == null);
}

test "upstream.anthropic Translator: 事件流/块收尾/finalize" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var translator = Translator.init(arena, "pkg");
    defer translator.deinit();

    // message_start：记录 id/input_tokens，不产 chunk
    try std.testing.expectEqual(@as(usize, 0), (try translator.translate("{\"type\":\"message_start\",\"message\":{\"id\":\"msg_1\",\"usage\":{\"input_tokens\":7}}}")).len);
    // thinking 块 + delta
    try std.testing.expectEqual(@as(usize, 0), (try translator.translate("{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"thinking\"}}")).len);
    const thinking = try translator.translate("{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"thinking_delta\",\"thinking\":\"想\"}}");
    try std.testing.expectEqualStrings("想", thinking[0].reasoning_delta.text);
    const stop_reasoning = try translator.translate("{\"type\":\"content_block_stop\",\"index\":0}");
    switch (stop_reasoning[0]) {
        .block_end => |end| try std.testing.expect(end.block == .reasoning),
        else => return error.UnexpectedChunk,
    }
    // tool_use 块 + 参数增量（name 恒 null：只有 block_end 才有）
    try std.testing.expectEqual(@as(usize, 0), (try translator.translate("{\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"tool_use\",\"id\":\"call_1\",\"name\":\"fn\"}}")).len);
    const tool_delta = try translator.translate("{\"type\":\"content_block_delta\",\"index\":1,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"a\\\":1}\"}}");
    try std.testing.expectEqualStrings("call_1", tool_delta[0].tool_delta.id);
    try std.testing.expect(tool_delta[0].tool_delta.name == null);
    // message_delta：stop_reason + output_tokens
    try std.testing.expectEqual(@as(usize, 0), (try translator.translate("{\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":9}}")).len);

    // finalize：关闭 open block（完整三元组）+ usage + finish
    const tail = try translator.finalize();
    try std.testing.expectEqual(@as(usize, 3), tail.len);
    switch (tail[0]) {
        .block_end => |end| switch (end.block) {
            .tool_call => |call| {
                try std.testing.expectEqualStrings("call_1", call.id);
                try std.testing.expectEqualStrings("fn", call.name);
                try std.testing.expectEqualStrings("{\"a\":1}", call.arguments);
            },
            else => return error.UnexpectedBlock,
        },
        else => return error.UnexpectedChunk,
    }
    try std.testing.expect(tail[1] == .usage);
    try std.testing.expectEqual(@as(u64, 7), tail[1].usage.input);
    try std.testing.expectEqual(@as(u64, 9), tail[1].usage.output);
    try std.testing.expect(tail[2] == .finish);
    try std.testing.expect(tail[2].finish == .tool_calls);
    // 幂等
    try std.testing.expectEqual(@as(usize, 0), (try translator.finalize()).len);
}

test "upstream.anthropic Translator: error 事件与畸形帧" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var translator = Translator.init(arena, "pkg");
    defer translator.deinit();

    const err = try translator.translate("{\"type\":\"error\",\"error\":{\"message\":\"boom\"}}");
    switch (err[0]) {
        .finish => |reason| {
            try std.testing.expect(reason == .failure);
            try std.testing.expectEqualStrings("SERVER", reason.failure.code);
            try std.testing.expect(std.mem.indexOf(u8, reason.failure.message, "boom") != null);
        },
        else => return error.UnexpectedChunk,
    }

    const malformed = try translator.translate("not json");
    switch (malformed[0]) {
        .finish => |reason| {
            try std.testing.expect(reason == .failure);
            try std.testing.expectEqualStrings("MALFORMED_RESPONSE", reason.failure.code);
        },
        else => return error.UnexpectedChunk,
    }
}

// ---------------------------------------------------------------------------
// 上游调用
// ---------------------------------------------------------------------------

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
    const url = try std.fmt.allocPrint(arena, "{s}/messages", .{std.mem.trimEnd(u8, profile.base_url, "/")});
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
            .{ .name = "x-api-key", .value = key },
            .{ .name = "anthropic-version", .value = "2023-06-01" },
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
        const retry_after = openai.retryAfterMs(response.head);
        var transfer_buffer: [16384]u8 = undefined;
        const body_reader = response.reader(&transfer_buffer);
        const error_body = body_reader.allocRemaining(arena, .limited(1 << 20)) catch "";
        failure_out.* = openai.mapFailure(status_code, error_body, retry_after);
        return error.UpstreamFailure;
    }

    var transfer_buffer: [16384]u8 = undefined;
    const body_reader = response.reader(&transfer_buffer);
    var translator = Translator.init(arena, "llm-shim");
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
