//! OpenAI Responses API 上游适配器。
//! 无状态屏蔽：store 恒 false、永不发 previous_response_id——每次全量重放。
const std = @import("std");
const types = @import("../types.zig");
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

/// 输入投影：IR → Responses input items JSON 数组文本。
fn serializeInput(
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

    for (request.messages) |message| {
        switch (message.role) {
            .system => {},
            .user => {
                var parts: std.ArrayList(u8) = .empty;
                var meaningful = false;
                for (message.blocks) |block| {
                    switch (block) {
                        .text => |text| {
                            if (text.len == 0) continue;
                            meaningful = true;
                            const part = try std.fmt.allocPrint(arena, "{{\"type\":\"input_text\",\"text\":{f}}}", .{std.json.fmt(text, .{})});
                            if (parts.items.len > 0) try parts.append(arena, ',');
                            try parts.appendSlice(arena, part);
                        },
                        .image => |image| {
                            meaningful = true;
                            if (vision) {
                                const part = try std.fmt.allocPrint(arena, "{{\"type\":\"input_image\",\"image_url\":{f}}}", .{std.json.fmt(image.data_uri, .{})});
                                if (parts.items.len > 0) try parts.append(arena, ',');
                                try parts.appendSlice(arena, part);
                            } else {
                                const part = try std.fmt.allocPrint(arena, "{{\"type\":\"input_text\",\"text\":{f}}}", .{std.json.fmt(placeholder, .{})});
                                if (parts.items.len > 0) try parts.append(arena, ',');
                                try parts.appendSlice(arena, part);
                            }
                        },
                        .reasoning, .tool_call => {},
                    }
                }
                if (!meaningful) continue;
                if (!first) try w.writeAll(",");
                first = false;
                try w.print("{{\"type\":\"message\",\"role\":\"user\",\"content\":[{s}]}}", .{parts.items});
            },
            .assistant => {
                for (message.blocks) |block| {
                    switch (block) {
                        .text => |text| {
                            if (text.len == 0) continue;
                            if (!first) try w.writeAll(",");
                            first = false;
                            try w.print("{{\"type\":\"message\",\"role\":\"assistant\",\"content\":[{{\"type\":\"output_text\",\"text\":{f}}}]}}", .{std.json.fmt(text, .{})});
                        },
                        .tool_call => |call| {
                            if (!first) try w.writeAll(",");
                            first = false;
                            try w.print("{{\"type\":\"function_call\",\"call_id\":{f},\"name\":{f},\"arguments\":{f}}}", .{
                                std.json.fmt(call.id, .{}), std.json.fmt(call.name, .{}), std.json.fmt(call.arguments, .{}),
                            });
                        },
                        .reasoning, .image => {},
                    }
                }
            },
            .tool => {
                var text: []const u8 = "";
                for (message.blocks) |block| {
                    if (block == .text and block.text.len > 0) {
                        text = block.text;
                        break;
                    }
                }
                if (!first) try w.writeAll(",");
                first = false;
                try w.print("{{\"type\":\"function_call_output\",\"call_id\":{f},\"output\":{f}}}", .{
                    std.json.fmt(toolIdOf(message), .{}),
                    std.json.fmt(if (text.len > 0) text else "(no output)", .{}),
                });
            },
        }
    }
    try w.writeAll("]");
    return out.written();
}

fn toolIdOf(message: types.Message) []const u8 {
    for (message.blocks) |block| {
        if (block == .tool_call) return block.tool_call.id;
    }
    return "";
}

pub fn serializeBody(
    arena: std.mem.Allocator,
    profile: *const providers_mod.Profile,
    request: types.GenerateRequest,
) ![]const u8 {
    const model = request.model;
    var out: std.Io.Writer.Allocating = .init(arena);
    const w = &out.writer;
    try w.print("{{\"model\":{f},\"input\":", .{std.json.fmt(model, .{})});
    try w.writeAll(try serializeInput(arena, profile, model, request));
    // 无状态屏蔽：store 恒 false；previous_response_id 永不发送
    try w.writeAll(",\"stream\":true,\"store\":false");
    if (request.system) |system| {
        if (system.len > 0) try w.print(",\"instructions\":{f}", .{std.json.fmt(system, .{})});
    }
    if (request.reasoning_effort) |effort| {
        // 档位：未知厂商恒省略（reasoning 片段策略）
        if (profile.effort_strategy != .omit_always) {
            if (@import("../effort.zig").mapEffort(profile.effort_strategy, model, effort)) |vendor_effort| {
                try w.print(",\"reasoning\":{{\"effort\":{f}}}", .{std.json.fmt(vendor_effort, .{})});
            }
        }
    }
    if (request.tools) |tools| {
        if (tools.len > 0) {
            try w.writeAll(",\"tools\":[");
            for (tools, 0..) |tool, index| {
                if (index > 0) try w.writeAll(",");
                try w.print("{{\"type\":\"function\",\"name\":{f},\"description\":{f},\"parameters\":{f}}}", .{
                    std.json.fmt(tool.name, .{}), std.json.fmt(tool.description, .{}), std.json.fmt(tool.parameters, .{}),
                });
            }
            try w.writeAll("]");
        }
    }
    if (request.temperature) |temperature| {
        try w.print(",\"temperature\":{d}", .{temperature});
    }
    if (request.max_tokens) |max_tokens| {
        try w.print(",\"max_output_tokens\":{d}", .{max_tokens});
    }
    // stop：Responses 无对应参数，静默丢弃
    try w.writeAll("}");
    return out.written();
}

// ---------------------------------------------------------------------------
// SSE → Chunk 翻译（TS: ResponsesStreamTranslator）
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

    fn pushBlock(self: *Translator, kind: types.BlockKind, tool_id: []const u8, tool_name: []const u8) !*OpenBlock {
        const block = try self.arena.create(OpenBlock);
        var name_list: std.ArrayList(u8) = .empty;
        try name_list.appendSlice(self.arena, tool_name);
        block.* = .{ .kind = kind, .index = self.next_index, .text = .empty, .tool_id = tool_id, .tool_name = name_list };
        self.next_index += 1;
        try self.open.append(self.arena, block);
        return block;
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

        if (std.mem.eql(u8, event_type, "response.created") or std.mem.eql(u8, event_type, "response.in_progress")) {
            if (root.get("response")) |response| {
                if (response == .object) {
                    if (response.object.get("id")) |id| {
                        if (id == .string) self.response_id = id.string;
                    }
                }
            }
        } else if (std.mem.eql(u8, event_type, "response.output_item.added")) {
            const item = root.get("item");
            const item_type = if (item != null and item.? == .object)
                (if (item.?.object.get("type")) |t| (if (t == .string) t.string else "message") else "message")
            else
                "message";
            if (std.mem.eql(u8, item_type, "function_call")) {
                const call_id = if (item != null and item.? == .object)
                    (if (item.?.object.get("call_id")) |t| (if (t == .string) t.string else "") else "")
                else
                    "";
                const name = if (item != null and item.? == .object)
                    (if (item.?.object.get("name")) |t| (if (t == .string) t.string else "") else "")
                else
                    "";
                _ = try self.pushBlock(.tool_call, if (call_id.len > 0) call_id else "resp-tool", name);
            } else if (std.mem.eql(u8, item_type, "reasoning")) {
                _ = try self.pushBlock(.reasoning, "", "");
            } else {
                _ = try self.pushBlock(.text, "", "");
            }
        } else if (std.mem.eql(u8, event_type, "response.output_text.delta")) {
            const delta = if (root.get("delta")) |d| (if (d == .string) d.string else "") else "";
            const block = if (self.open.items.len > 0) self.open.items[self.open.items.len - 1] else null;
            if (delta.len > 0) {
                if (block) |b| {
                    try b.text.appendSlice(self.arena, delta);
                    try self.chunks.append(self.arena, .{ .text_delta = .{ .index = b.index, .text = delta } });
                }
            }
        } else if (std.mem.eql(u8, event_type, "response.reasoning_summary_text.delta") or std.mem.eql(u8, event_type, "response.reasoning_text.delta")) {
            const delta = if (root.get("delta")) |d| (if (d == .string) d.string else "") else "";
            if (delta.len > 0) {
                const block = findBlock(self.open.items, .reasoning) orelse (if (self.open.items.len > 0) self.open.items[self.open.items.len - 1] else null);
                if (block) |b| {
                    try b.text.appendSlice(self.arena, delta);
                    try self.chunks.append(self.arena, .{ .reasoning_delta = .{ .index = b.index, .text = delta } });
                }
            }
        } else if (std.mem.eql(u8, event_type, "response.function_call_arguments.delta")) {
            const delta = if (root.get("delta")) |d| (if (d == .string) d.string else "") else "";
            if (delta.len > 0) {
                const block = findBlockReverse(self.open.items, .tool_call);
                if (block) |b| {
                    try b.text.appendSlice(self.arena, delta);
                    try self.chunks.append(self.arena, .{ .tool_delta = .{ .index = b.index, .id = b.tool_id, .name = null, .args_delta = delta } });
                }
            }
        } else if (std.mem.eql(u8, event_type, "response.output_item.done")) {
            const block = if (self.open.items.len > 0) self.open.pop() else null;
            if (block) |b| {
                switch (b.kind) {
                    .text => try self.chunks.append(self.arena, .{ .block_end = .{ .index = b.index, .block = .{ .text = b.text.items } } }),
                    .reasoning => try self.chunks.append(self.arena, .{ .block_end = .{ .index = b.index, .block = .{ .reasoning = b.text.items } } }),
                    .tool_call => try self.chunks.append(self.arena, .{ .block_end = .{ .index = b.index, .block = .{ .tool_call = .{ .id = b.tool_id, .name = b.tool_name.items, .arguments = b.text.items } } } }),
                }
            }
        } else if (std.mem.eql(u8, event_type, "response.completed")) {
            if (root.get("response")) |response| {
                if (response == .object) {
                    if (response.object.get("id")) |id| {
                        if (id == .string) self.response_id = id.string;
                    }
                    if (response.object.get("usage")) |usage| {
                        if (usage == .object) {
                            if (openai.jsonInt(usage.object, "input_tokens")) |tokens| self.input_tokens = tokens;
                            if (openai.jsonInt(usage.object, "output_tokens")) |tokens| self.output_tokens = tokens;
                        }
                    }
                }
            }
            self.pending_finish = .stop;
        } else if (std.mem.eql(u8, event_type, "response.incomplete")) {
            self.pending_finish = .max_tokens;
        } else if (std.mem.eql(u8, event_type, "response.failed")) {
            const message = blk: {
                if (root.get("response")) |response| {
                    if (response == .object) {
                        if (response.object.get("error")) |error_value| {
                            if (error_value == .object) {
                                if (error_value.object.get("message")) |m| {
                                    if (m == .string) break :blk m.string;
                                }
                            }
                        }
                    }
                }
                break :blk "response failed";
            };
            try self.chunks.append(self.arena, try openai.failureChunk(self.arena, self.pkg, message, "SERVER"));
        }
        return self.chunks.items;
    }

    pub fn finalize(self: *Translator) ![]const types.Chunk {
        self.chunks.clearRetainingCapacity();
        if (self.finished) return self.chunks.items;
        for (self.open.items) |block| {
            switch (block.kind) {
                .text => try self.chunks.append(self.arena, .{ .block_end = .{ .index = block.index, .block = .{ .text = block.text.items } } }),
                .reasoning => try self.chunks.append(self.arena, .{ .block_end = .{ .index = block.index, .block = .{ .reasoning = block.text.items } } }),
                .tool_call => try self.chunks.append(self.arena, .{ .block_end = .{ .index = block.index, .block = .{ .tool_call = .{ .id = block.tool_id, .name = block.tool_name.items, .arguments = block.text.items } } } }),
            }
        }
        try self.chunks.append(self.arena, .{ .usage = .{ .input = self.input_tokens, .output = self.output_tokens, .total = self.input_tokens + self.output_tokens } });
        try self.chunks.append(self.arena, .{ .finish = self.pending_finish orelse .stop });
        self.finished = true;
        return self.chunks.items;
    }
};

fn findBlock(open: []const *OpenBlock, kind: types.BlockKind) ?*OpenBlock {
    for (open) |block| {
        if (block.kind == kind) return block;
    }
    return null;
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
        .protocol = .responses,
        .models = &test_models,
    };
}

fn expectContains(haystack: []const u8, needle: []const u8) !void {
    try std.testing.expect(std.mem.indexOf(u8, haystack, needle) != null);
}

test "upstream.responses serializeBody: 无状态恒发 / 档位策略 / stop 丢弃" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const base = testProfile();
    var request = types.GenerateRequest{
        .provider = "p",
        .model = "text-model",
        .messages = &.{},
        .reasoning_effort = .high,
        .max_tokens = 77,
        .stop = &.{"END"},
        .system = "SYS",
    };

    const body = try serializeBody(arena, &base, request);
    try expectContains(body, "\"stream\":true");
    try expectContains(body, "\"store\":false"); // 无状态屏蔽恒发
    try expectContains(body, "\"instructions\":\"SYS\"");
    try expectContains(body, "\"max_output_tokens\":77");
    try std.testing.expect(std.mem.indexOf(u8, body, "\"stop\"") == null); // Responses 无 stop，静默丢弃
    try std.testing.expect(std.mem.indexOf(u8, body, "reasoning") == null); // omit_always（默认）→ 省略

    var passthrough = base;
    passthrough.effort_strategy = .passthrough;
    const body2 = try serializeBody(arena, &passthrough, request);
    try expectContains(body2, "\"reasoning\":{\"effort\":\"high\"}");

    // tools 用 type=function 平铺形态
    const tools = [_]types.ToolSchema{.{ .name = "fn", .description = "d", .parameters = .{ .object = std.json.ObjectMap.empty } }};
    request.tools = &tools;
    const body3 = try serializeBody(arena, &passthrough, request);
    try expectContains(body3, "\"tools\":[{\"type\":\"function\",\"name\":\"fn\"");
}

test "upstream.responses serializeInput: 角色投影与占位" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const profile = testProfile();

    const messages = [_]types.Message{
        .{ .role = .user, .blocks = &.{ .{ .text = "看图" }, .{ .image = .{ .data_uri = "data:image/png;base64,AQID" } } } },
        .{ .role = .assistant, .blocks = &.{ .{ .text = "答" }, .{ .tool_call = .{ .id = "c1", .name = "fn", .arguments = "{\"a\":1}" } } } },
        .{ .role = .tool, .blocks = &.{ .{ .tool_call = .{ .id = "c1", .name = "", .arguments = "{}" } }, .{ .text = "" } } },
    };
    const request = types.GenerateRequest{ .provider = "p", .model = "vision-model", .messages = &messages };

    const body = try serializeInput(arena, &profile, "vision-model", request);
    try expectContains(body, "\"type\":\"input_image\",\"image_url\":\"data:image/png;base64,AQID\"");
    try expectContains(body, "\"type\":\"output_text\",\"text\":\"答\"");
    try expectContains(body, "\"type\":\"function_call\",\"call_id\":\"c1\",\"name\":\"fn\"");
    try expectContains(body, "\"type\":\"function_call_output\",\"call_id\":\"c1\",\"output\":\"(no output)\"");

    const plain = try serializeInput(arena, &profile, "text-model", request);
    try expectContains(plain, "[图片已省略"); // 非视觉 → 占位
    try std.testing.expect(std.mem.indexOf(u8, plain, "input_image") == null);
}

test "upstream.responses Translator: added/done 配对与三态收尾" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var translator = Translator.init(arena, "pkg");
    defer translator.deinit();

    // response.created：记录 id，不产 chunk
    try std.testing.expectEqual(@as(usize, 0), (try translator.translate("{\"type\":\"response.created\",\"response\":{\"id\":\"resp_1\"}}")).len);
    // output_item.added(function_call) → 无 chunk（仅开块）
    try std.testing.expectEqual(@as(usize, 0), (try translator.translate("{\"type\":\"response.output_item.added\",\"item\":{\"type\":\"function_call\",\"call_id\":\"call_1\",\"name\":\"fn\"}}")).len);
    // 参数增量 → tool_delta（id 来自块，name 恒 null）
    const args = try translator.translate("{\"type\":\"response.function_call_arguments.delta\",\"delta\":\"{\\\"a\\\":1}\"}");
    try std.testing.expectEqualStrings("call_1", args[0].tool_delta.id);
    try std.testing.expect(args[0].tool_delta.name == null);
    // output_item.done → block_end 完整三元组
    const done = try translator.translate("{\"type\":\"response.output_item.done\"}");
    switch (done[0]) {
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
    // completed：usage + stop；finalize 补 usage+finish
    try std.testing.expectEqual(@as(usize, 0), (try translator.translate("{\"type\":\"response.completed\",\"response\":{\"usage\":{\"input_tokens\":4,\"output_tokens\":6}}}")).len);
    const tail = try translator.finalize();
    try std.testing.expectEqual(@as(usize, 2), tail.len);
    try std.testing.expect(tail[0] == .usage);
    try std.testing.expectEqual(@as(u64, 4), tail[0].usage.input);
    try std.testing.expect(tail[1] == .finish);
    try std.testing.expect(tail[1].finish == .stop);
    try std.testing.expectEqual(@as(usize, 0), (try translator.finalize()).len); // 幂等
}

test "upstream.responses Translator: incomplete/failed/文本增量" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var translator = Translator.init(arena, "pkg");
    defer translator.deinit();
    // 文本：added(message) + output_text.delta
    try std.testing.expectEqual(@as(usize, 0), (try translator.translate("{\"type\":\"response.output_item.added\",\"item\":{\"type\":\"message\"}}")).len);
    const text = try translator.translate("{\"type\":\"response.output_text.delta\",\"delta\":\"hi\"}");
    try std.testing.expectEqualStrings("hi", text[0].text_delta.text);
    // incomplete → max_tokens；此时文本块仍开放 → finalize 依次补齐
    // block_end(text) + usage + finish（与 openai 上游 finalize 的收尾顺序一致）
    try std.testing.expectEqual(@as(usize, 0), (try translator.translate("{\"type\":\"response.incomplete\"}")).len);
    const tail = try translator.finalize();
    try std.testing.expectEqual(@as(usize, 3), tail.len);
    try std.testing.expect(tail[0] == .block_end);
    try std.testing.expect(tail[1] == .usage);
    switch (tail[2]) {
        .finish => |reason| try std.testing.expect(reason == .max_tokens),
        else => return error.UnexpectedChunk,
    }

    var failed = Translator.init(arena, "pkg");
    defer failed.deinit();
    const failure = try failed.translate("{\"type\":\"response.failed\",\"response\":{\"error\":{\"message\":\"boom\"}}}");
    switch (failure[0]) {
        .finish => |reason| {
            try std.testing.expect(reason == .failure);
            try std.testing.expectEqualStrings("SERVER", reason.failure.code);
        },
        else => return error.UnexpectedChunk,
    }
    const malformed = try failed.translate("nope");
    switch (malformed[0]) {
        .finish => |reason| try std.testing.expectEqualStrings("MALFORMED_RESPONSE", reason.failure.code),
        else => return error.UnexpectedChunk,
    }
}

fn findBlockReverse(open: []const *OpenBlock, kind: types.BlockKind) ?*OpenBlock {
    var index = open.len;
    while (index > 0) {
        index -= 1;
        if (open[index].kind == kind) return open[index];
    }
    return null;
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
    const url = try std.fmt.allocPrint(arena, "{s}/responses", .{std.mem.trimEnd(u8, profile.base_url, "/")});
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
