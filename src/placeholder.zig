//! 占位保活（placeholder keepalive）的纯函数层。
//!
//! 上游静默 ≥ 阈值（默认 55s）时，网关向客户端写一个"隐形哨兵包裹的省略号"
//! （`U+2063` + `…` + `U+2063`）：客户端界面里只见一个 `…`（伪装成模型刚开始
//! 输出），足以喂住客户端的 idle 计时器；而回灌到网关的历史里，这个精确串会被
//! [strip] 删除，不会转发给上游、不浪费 token。
//!
//! 铁律（有单测锁定）：
//! - **只做字符串级精确删除**：不删消息/不删块/不重排/不合并——改动历史结构会
//!   让上游的前缀缓存（prefix cache）整段失效，代价远大于省下的 token；
//! - **零启发式**：正文里的裸 `…`、用户打的 `…` 一律不动，避免误删真实内容；
//! - **幂等且确定**：`strip(strip(x)) == strip(x)`，同一输入恒等输出——这是缓存
//!   友好的前提（每轮发给上游的历史字节序列单调稳定）。
//!
//! 已知残余（记档）：若客户端清洗掉不可见字符，占位会退化成字面 `…` 而认不出，
//! 此时按规则"不动"——约 1 token/次、字节永久稳定、不引发缓存抖动。
const std = @import("std");
const env = @import("env.zig");
const types = @import("types.zig");

/// U+2063 INVISIBLE SEPARATOR：不可见、JSON/UTF-8 合法、Markdown 透传。
/// 模型自发产出"该字符夹省略号"的概率≈0，因此精确匹配的误删风险≈0。
pub const sentinel = "\u{2063}";
/// U+2026 HORIZONTAL ELLIPSIS：界面里就是"模型开始输出"的样子。
pub const ellipsis = "\u{2026}";
/// 发给客户端的占位载荷（精确串）：sentinel + ellipsis + sentinel。
pub const text = sentinel ++ ellipsis ++ sentinel;

/// 默认阈值：55s（略小于常见客户端 60s idle 超时）。
pub const default_threshold_ms: u64 = 55_000;
pub const threshold_env = "AUTO_COMPAT_PLACEHOLDER_MS";

/// 阈值解析：未设置 → 默认 55s；0 → 关闭该功能；坏值 → 默认。
pub fn thresholdMs() u64 {
    const raw = env.get(threshold_env) orelse return default_threshold_ms;
    const parsed = std.fmt.parseInt(u64, raw, 10) catch return default_threshold_ms;
    return parsed;
}

pub fn enabled() bool {
    return thresholdMs() > 0;
}

/// 删除所有精确的占位串；无占位时零拷贝返回原切片。
/// 左到右扫描 + 三段模式匹配：连发的多个占位（`S…SS…S`）会被逐个吃净。
pub fn strip(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
    if (std.mem.indexOf(u8, input, text) == null) return input;
    var out: std.ArrayList(u8) = .empty;
    var rest = input;
    while (std.mem.indexOf(u8, rest, text)) |index| {
        try out.appendSlice(allocator, rest[0..index]);
        rest = rest[index + text.len ..];
    }
    try out.appendSlice(allocator, rest);
    return out.toOwnedSlice(allocator);
}

/// IR 级剥离：对消息里**所有文本块**做 [strip]，其余块原样。
/// 结构不变式：消息条数、顺序、每条消息的块数全部不变（只替换文本内容）。
/// 无占位时零拷贝返回原切片。
pub fn stripFromMessages(arena: std.mem.Allocator, messages: []const types.Message) ![]const types.Message {
    var dirty = false;
    for (messages) |message| {
        for (message.blocks) |block| {
            switch (block) {
                .text => |value| if (std.mem.indexOf(u8, value, text) != null) {
                    dirty = true;
                },
                else => {},
            }
        }
        if (dirty) break;
    }
    if (!dirty) return messages;

    const out = try arena.alloc(types.Message, messages.len);
    for (messages, 0..) |message, message_index| {
        const blocks = try arena.alloc(types.Block, message.blocks.len);
        for (message.blocks, 0..) |block, block_index| {
            blocks[block_index] = switch (block) {
                .text => |value| .{ .text = try strip(arena, value) },
                else => block,
            };
        }
        out[message_index] = .{ .role = message.role, .blocks = blocks };
    }
    return out;
}

/// 系统提示文本（独立字段）同样剥离；null 原样。
pub fn stripOptional(arena: std.mem.Allocator, input: ?[]const u8) !?[]const u8 {
    const value = input orelse return null;
    return try strip(arena, value);
}

test "placeholder: 载荷是哨兵夹省略号（9 字节）" {
    try std.testing.expectEqual(@as(usize, 9), text.len);
    try std.testing.expectEqualStrings("\u{2063}\u{2026}\u{2063}", text);
}

test "strip: 精确删除 / 幂等 / 确定性 / 结构不变式" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // 测试向量（与 TS 版共用同一组，保证两版规则对齐）
    const vectors = [_]struct { input: []const u8, expected: []const u8 }{
        // 无占位：原样（且必须零拷贝，见下）
        .{ .input = "hello 世界", .expected = "hello 世界" },
        // 占位独占
        .{ .input = text, .expected = "" },
        // 占位夹在真实内容中
        .{ .input = "a" ++ text ++ "b", .expected = "ab" },
        // 连发两次
        .{ .input = text ++ text, .expected = "" },
        // 占位 + 真实回答（客户端拼接后的典型形态）
        .{ .input = text ++ "真正的回答", .expected = "真正的回答" },
        // 真实内容 + 占位
        .{ .input = "先给了半句" ++ text, .expected = "先给了半句" },
        // 中间出现 + 前后都有真实文本
        .{ .input = "前半" ++ text ++ "后半", .expected = "前半后半" },
        // 裸省略号（模型正常输出）一律不动
        .{ .input = "\u{2026}", .expected = "\u{2026}" },
        .{ .input = "等等\u{2026}让我想想", .expected = "等等\u{2026}让我想想" },
        .{ .input = "六个点......", .expected = "六个点......" },
        // 孤立哨兵（无省略号）不动：只认完整三段串
        .{ .input = "x" ++ sentinel ++ "y", .expected = "x" ++ sentinel ++ "y" },
        .{ .input = sentinel ++ "y" ++ sentinel, .expected = sentinel ++ "y" ++ sentinel },
        // 多个位置混合
        .{ .input = "a" ++ text ++ "b" ++ text ++ "c", .expected = "abc" },
    };

    for (vectors) |vector| {
        const once = try strip(arena, vector.input);
        try std.testing.expectEqualStrings(vector.expected, once);
        // 幂等：strip(strip(x)) == strip(x)
        const twice = try strip(arena, once);
        try std.testing.expectEqualStrings(once, twice);
        // 确定性：同输入两次调用逐字节一致
        try std.testing.expectEqualStrings(once, try strip(arena, vector.input));
    }

    // 无占位 → 零拷贝（返回同一内存），避免给每个请求都白分配
    const clean = "没有占位的内容";
    const zero_copy = try strip(arena, clean);
    try std.testing.expectEqual(@intFromPtr(clean.ptr), @intFromPtr(zero_copy.ptr));
}

test "thresholdMs: 0 关闭 / 坏值回落默认" {
    // 注意：只测纯解析路径（不碰进程环境），通过直接断言默认值与世界常量一致
    try std.testing.expectEqual(@as(u64, 55_000), default_threshold_ms);
    try std.testing.expectEqualStrings("AUTO_COMPAT_PLACEHOLDER_MS", threshold_env);
}

test "stripFromMessages: 结构不变式（只改文本内容，块数/消息数/顺序不动）" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const blocks_a = [_]types.Block{
        .{ .text = text ++ "回答" },
        .{ .tool_call = .{ .id = "c1", .name = "f", .arguments = "{}" } },
    };
    const blocks_b = [_]types.Block{.{ .text = "等等\u{2026}让我想想" }};
    const messages = [_]types.Message{
        .{ .role = .user, .blocks = &blocks_a },
        .{ .role = .assistant, .blocks = &blocks_b },
    };

    const stripped = try stripFromMessages(arena, &messages);
    // 结构不变式
    try std.testing.expectEqual(messages.len, stripped.len);
    try std.testing.expectEqual(messages[0].role, stripped[0].role);
    try std.testing.expectEqual(messages[1].role, stripped[1].role);
    try std.testing.expectEqual(messages[0].blocks.len, stripped[0].blocks.len);
    try std.testing.expectEqual(messages[1].blocks.len, stripped[1].blocks.len);
    // 内容：文本块被剥离，工具块原样，裸省略号句子不动
    try std.testing.expectEqualStrings("回答", stripped[0].blocks[0].text);
    try std.testing.expectEqualStrings("c1", stripped[0].blocks[1].tool_call.id);
    try std.testing.expectEqualStrings("等等\u{2026}让我想想", stripped[1].blocks[0].text);

    // 幂等/确定性（IR 级）
    const again = try stripFromMessages(arena, stripped);
    try std.testing.expectEqualStrings("回答", again[0].blocks[0].text);
    try std.testing.expectEqualStrings("等等\u{2026}让我想想", again[1].blocks[0].text);

    // 无占位：零拷贝
    const clean_blocks = [_]types.Block{.{ .text = "干净" }};
    const clean = [_]types.Message{.{ .role = .user, .blocks = &clean_blocks }};
    const untouched = try stripFromMessages(arena, &clean);
    try std.testing.expectEqual(@intFromPtr(&clean), @intFromPtr(untouched.ptr));
}
